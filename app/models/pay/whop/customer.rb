module Pay
  module Whop
    class Customer < Pay::Customer
      has_many :charges, dependent: :destroy, class_name: "Pay::Whop::Charge"
      has_many :subscriptions, dependent: :destroy, class_name: "Pay::Whop::Subscription"
      has_many :payment_methods, dependent: :destroy, class_name: "Pay::Whop::PaymentMethod"

      def checkout(variant_id:, redirect_url:, name: Pay.default_product_name, metadata: {}, idempotency_key: SecureRandom.uuid)
        Whop.validate_configuration!
        with_lock do
          if data.to_h["whop_account_id"].present?
            verify_configuration!
          else
            update!(data: data.to_h.merge("whop_account_id" => Whop.account_id, "whop_environment" => Whop.environment))
          end
        end
        Whop.client.checkout_configurations.create(
          account_id: Whop.account_id, variant_id: variant_id, redirect_url: redirect_url,
          metadata: metadata.stringify_keys.merge("pay_customer" => signed_id(purpose: Whop.identity_purpose), "pay_subscription_name" => name),
          request_options: Whop.request_options(idempotency_key: idempotency_key)
        )
      end

      def verify_configuration!
        unless data.to_h.values_at("whop_account_id", "whop_environment") == [Whop.account_id, Whop.environment]
          raise IdentityError, "Pay customer belongs to another Whop account or environment"
        end
      end

      def api_record
        verify_configuration!
        raise Error, "Customer has not completed a Whop checkout" if processor_id.blank?
        Whop.client.members.retrieve(id: processor_id, request_options: Whop.request_options)
      end

      def update_api_record(**attributes)
        # Whop owns the buyer's email; changing it locally must not change their Whop identity.
        nil
      end

      def whop? = true

      %i[charge subscribe add_payment_method update_payment_method invoice!].each do |operation|
        define_method(operation) do |*args, **options|
          raise Pay::NotSupportedError, "Use Whop hosted checkout; #{operation} is not supported by pay-whop yet"
        end
      end

      def self.resolve!(object)
        Whop.verify_account!(object)
        member_id = object.fetch("member_id")
        raise IdentityError, "Whop resource has no member" if member_id.blank?
        token = object.dig("metadata", "pay_customer")
        signed_customer = find_signed(token, purpose: Whop.identity_purpose) if token.present?
        raise IdentityError, "Invalid Pay customer reference" if token.present? && signed_customer.nil?
        existing = find_by(processor_id: member_id)
        if existing && signed_customer && existing.id != signed_customer.id
          raise IdentityError, "Whop member is already linked to a different Pay customer"
        end
        customer = signed_customer || existing
        raise IdentityError, "Whop resource is not linked to a Pay customer" unless customer
        customer.verify_configuration!
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
