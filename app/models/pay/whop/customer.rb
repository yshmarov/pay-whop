module Pay
  module Whop
    class Customer < Pay::Customer
      has_many :charges, dependent: :destroy, class_name: "Pay::Whop::Charge"
      has_many :subscriptions, dependent: :destroy, class_name: "Pay::Whop::Subscription"
      has_many :payment_methods, dependent: :destroy, class_name: "Pay::Whop::PaymentMethod"

      has_many :entitlements, class_name: "Pay::Whop::Entitlement", dependent: :destroy
      has_many :disputes, class_name: "Pay::Whop::Dispute", dependent: :destroy
      has_many :invoices, class_name: "Pay::Whop::Invoice", dependent: :destroy
      has_one :default_payment_method, -> { where(default: true) }, class_name: "Pay::Whop::PaymentMethod", foreign_key: :customer_id

      def account_id = data.to_h["whop_account_id"] || Whop.account_id

      def checkout(redirect_url:, variant_id: nil, variant: nil, name: Pay.default_product_name, metadata: {}, mode: "payment", idempotency_key: SecureRandom.uuid, **options)
        bind_account!
        raise ArgumentError, "Choose a variant or variant_id" if mode == "payment" && [variant_id, variant].compact.size != 1
        raise ArgumentError, "Unknown checkout option" unless (options.keys - %i[affiliate_code currency payment_method_configuration three_ds_level]).empty?
        Whop.api.checkout_configurations.create(**options,
          account_id: account_id, variant_id: variant_id, variant: variant, mode: mode, redirect_url: redirect_url,
          metadata: checkout_metadata(metadata, name: name),
          request_options: Whop.request_options(idempotency_key: idempotency_key))
      end

      def checkout_charge(amount:, redirect_url:, currency: "usd", decimals: 2, application_fee_amount: nil, **options)
        variant = {currency: currency, billing_type: "one_time", initial_price: Whop.major_units(amount, decimals: decimals)}
        if application_fee_amount
          raise ArgumentError, "Application fee must be below the price" unless application_fee_amount < amount
          variant[:application_fee_amount] = Whop.major_units(application_fee_amount, decimals: decimals)
        end
        checkout(variant: variant, redirect_url: redirect_url, **options)
      end

      def setup_checkout(redirect_url:, **options)
        checkout(redirect_url: redirect_url, mode: "setup", **options)
      end

      def checkout_metadata(metadata = {}, name: Pay.default_product_name)
        metadata.stringify_keys.merge("pay_customer" => signed_id(purpose: Whop.identity_purpose(account_id)), "pay_subscription_name" => name)
      end

      def bind_account!
        Whop.validate_configuration!
        with_lock do
          if data.to_h["whop_account_id"].present?
            verify_configuration!
          else
            update!(data: data.to_h.merge("whop_account_id" => Whop.account_id, "whop_environment" => Whop.environment))
          end
        end
      end

      def verify_configuration!
        unless data.to_h["whop_environment"] == Whop.environment && data.to_h["whop_account_id"].present?
          raise IdentityError, "Pay customer belongs to another Whop environment"
        end
        Whop.verify_account!({"account_id" => account_id})
      end

      def verify_resource!(object)
        verify_configuration!
        Whop.verify_account!(object, expected: account_id)
        unless self.class.resolve!(object).id == id
          raise IdentityError, "Whop resource belongs to another customer"
        end
        object
      end

      def sync_payment_methods
        verify_configuration!
        raise Error, "Complete checkout or payment setup first" if processor_id.blank?
        ids = []
        Whop.each_page(Whop.api.payment_methods, member_id: processor_id) do |object|
          ids << PaymentMethod.sync(object, customer: self).processor_id
        end
        payment_methods.where.not(processor_id: ids).destroy_all
        payment_methods.reload
      end

      def add_payment_method(payment_method_id, default: false)
        sync_payment_methods
        method = payment_methods.find_by!(processor_id: payment_method_id)
        method.make_default! if default
        method
      end

      def create_setup_intent(confirmation_token:, return_url:, currency: "usd", metadata: {}, idempotency_key: SecureRandom.uuid)
        bind_account!
        Whop.api.setup_intents.create(account_id: account_id, confirmation_token: confirmation_token,
          return_url: return_url, currency: currency, metadata: checkout_metadata(metadata),
          request_options: Whop.request_options(idempotency_key: idempotency_key))
      end

      def create_payment_intent(confirmation_token:, return_url:, variant_id: nil, variant: nil, metadata: {}, capture: true, idempotency_key: SecureRandom.uuid)
        bind_account!
        raise ArgumentError, "Choose a variant or variant_id" unless [variant_id, variant].compact.size == 1
        Whop.api.payments.create(account_id: account_id, confirmation_token: confirmation_token,
          return_url: return_url, variant_id: variant_id, variant: variant, capture: capture,
          metadata: checkout_metadata(metadata), request_options: Whop.request_options(idempotency_key: idempotency_key))
      end

      def billing_portal(name: Pay.default_product_name)
        verify_configuration!
        subscription(name: name)&.portal_url || raise(Error, "No Whop membership management URL is available")
      end

      def create_payment(variant_id: nil, variant: nil, payment_method_id: nil, off_session: true, return_url: nil, metadata: {}, name: Pay.default_product_name, capture: true, idempotency_key: SecureRandom.uuid)
        verify_configuration!
        raise ArgumentError, "Choose a variant or variant_id" unless [variant_id, variant].compact.size == 1
        method = payment_method_id ? add_payment_method(payment_method_id) : default_payment_method
        raise Error, "Save a payment method and select a default first" unless method
        Whop.api.payments.create(account_id: account_id, member_id: processor_id,
          payment_method_id: method.processor_id, variant_id: variant_id, variant: variant,
          off_session: off_session, return_url: return_url, capture: capture,
          metadata: checkout_metadata(metadata, name: name), request_options: Whop.request_options(idempotency_key: idempotency_key))
      end

      def charge(amount, currency: "usd", decimals: 2, **options)
        result = create_payment(variant: {currency: currency, billing_type: "one_time", initial_price: Whop.major_units(amount, decimals: decimals)}, **options)
        confirmed_charge(result)
      end

      def subscribe(plan:, name: Pay.default_product_name, **options)
        result = create_payment(variant_id: plan, name: name, **options)
        confirmed_charge(result).subscription || raise(Error, "Payment did not create a recurring subscription")
      end

      def authorize(amount, currency: "usd", decimals: 2, **options)
        create_payment(variant: {currency: currency, billing_type: "one_time", initial_price: Whop.major_units(amount, decimals: decimals)}, capture: false, **options)
      end

      def payment(id)
        result = Whop.api.payments.retrieve(id: id, request_options: Whop.request_options)
        object = Whop.api_attributes(result)
        raise InvalidPayload, "Unexpected payment ID" unless object.fetch("id") == id
        verify_resource!(object)
        result
      end

      def capture(payment_id, idempotency_key: SecureRandom.uuid)
        payment(payment_id)
        Whop.api.payments.capture(id: payment_id, request_options: Whop.request_options(idempotency_key: idempotency_key))
        confirmed_charge(payment(payment_id))
      end

      def void(payment_id, idempotency_key: SecureRandom.uuid)
        payment(payment_id)
        Whop.api.payments.void(id: payment_id, request_options: Whop.request_options(idempotency_key: idempotency_key))
      end

      def retry_payment(payment_id, idempotency_key: SecureRandom.uuid)
        payment(payment_id)
        Whop.api.payments.retry_(id: payment_id, request_options: Whop.request_options(idempotency_key: idempotency_key))
        confirmed_charge(payment(payment_id))
      end

      def confirmed_charge(result)
        verify_resource!(Whop.api_attributes(result))
        raise PaymentIncomplete, result unless result.status == "paid"
        Charge.sync(result.id, account_id: account_id)
      end

      def create_invoice(items:, metadata: {}, idempotency_key: SecureRandom.uuid, **options)
        verify_configuration!
        raise Error, "Complete checkout or payment setup first" if processor_id.blank?
        raise ArgumentError, "Unknown invoice option" unless (options.keys - %i[due_at memo payment_method_id]).empty?
        add_payment_method(options[:payment_method_id]) if options[:payment_method_id]
        result = Whop.api.invoices.create(**options, account_id: account_id, member_id: processor_id, items: items,
          metadata: checkout_metadata(metadata), request_options: Whop.request_options(idempotency_key: idempotency_key))
        Invoice.sync(result.id, account_id: account_id)
      end

      def invoice!(idempotency_key: SecureRandom.uuid, **options)
        create_invoice(**options, idempotency_key: idempotency_key).issue(idempotency_key: "#{idempotency_key}-issue")
      end

      def sync_subscriptions
        verify_configuration!
        raise Error, "Customer has not completed checkout" if processor_id.blank?
        Whop.each_page(Whop.api.memberships, account_id: account_id, member_id: processor_id) do |object|
          verify_resource!(object)
          Subscription.sync(object.fetch("id"), account_id: account_id)
        end
        subscriptions.reload
      end

      def reconcile!
        verify_configuration!
        raise Error, "Customer has not completed checkout" if processor_id.blank?
        counts = {memberships: 0, payments: 0, invoices: 0, skipped: 0}
        {memberships: Whop.api.memberships, payments: Whop.api.payments, invoices: Whop.api.invoices}.each do |kind, endpoint|
          Whop.each_page(endpoint, account_id: account_id, member_id: processor_id) do |object|
            Whop.verify_account!(object, expected: account_id)
            raise IdentityError, "Reconciliation returned another member" unless object["member_id"] == processor_id
            token = object.dig("metadata", "pay_customer")
            if token.present? && self.class.find_signed(token, purpose: Whop.identity_purpose(account_id)).nil?
              counts[:skipped] += 1
              ActiveSupport::Notifications.instrument("reconciliation_skipped.pay_whop", customer_id: id, resource_id: object.fetch("id"), resource_type: kind)
              next
            end
            verify_resource!(object)
            case kind
            when :memberships then Subscription.sync(object.fetch("id"), account_id: account_id)
            when :payments then Charge.sync(object.fetch("id"), account_id: account_id)
            when :invoices then Invoice.sync(object.fetch("id"), account_id: account_id)
            end
            counts[kind] += 1
          end
        end
        counts
      end

      def api_record
        verify_configuration!
        raise Error, "Customer has not completed a Whop checkout" if processor_id.blank?
        Whop.api.members.retrieve(id: processor_id, request_options: Whop.request_options)
      end

      def update_api_record(**attributes)
        # Whop owns the buyer's email; changing it locally must not change their Whop identity.
        nil
      end

      def whop? = true

      def self.resolve!(object)
        account = Whop.verify_account!(object)
        member_id = object.fetch("member_id")
        raise IdentityError, "Whop resource has no member" if member_id.blank?
        token = object.dig("metadata", "pay_customer")
        signed_customer = find_signed(token, purpose: Whop.identity_purpose(account)) if token.present?
        raise IdentityError, "Invalid Pay customer reference" if token.present? && signed_customer.nil?
        existing = find_by(processor_id: member_id)
        if existing && signed_customer && existing.id != signed_customer.id
          raise IdentityError, "Whop member is already linked to a different Pay customer"
        end
        customer = signed_customer || existing
        raise IdentityError, "Whop resource is not linked to a Pay customer" unless customer
        customer.verify_configuration!
        raise IdentityError, "Customer belongs to another seller" unless customer.account_id == account
        customer.with_lock do
          if customer.processor_id.present? && customer.processor_id != member_id
            raise IdentityError, "Pay customer is already linked to a different Whop member"
          end
          customer.update!(processor_id: member_id) if customer.processor_id.blank?
        end
        customer
      end
    end
  end
end
