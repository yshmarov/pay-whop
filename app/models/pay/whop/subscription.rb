module Pay
  module Whop
    class Subscription < Pay::Subscription
      def self.sync(id, account_id: nil, customer: nil)
        object = Whop.api_attributes(Whop.api.memberships.retrieve(id: id, request_options: Whop.request_options))
        raise InvalidPayload, "Unexpected membership ID" unless object.fetch("id") == id
        Whop.verify_account!(object, expected: account_id)
        customer&.verify_resource!(object)
        customer ||= Customer.resolve!(object)
        unless object["renewal_price"].present?
          Entitlement.sync_object(object, account_id: customer.account_id)
          return
        end
        customer.with_lock do
          record = customer.subscriptions.find_or_initialize_by(processor_id: id)
          source_time = Whop.timestamp(object.fetch("updated_at"))
          saved_time = Whop.timestamp(record.data.to_h["whop_updated_at"])
          return record if saved_time && saved_time > source_time
          status = object.fetch("status")
          status = {"drafted" => "incomplete", "unresolved" => "incomplete", "canceling" => "active", "expired" => "canceled"}.fetch(status, status)
          ends_at = if %w[canceled expired].include?(object["status"])
            object["canceled_at"].presence || object["expires_at"].presence || object.fetch("updated_at")
          elsif object["cancel_at_period_end"]
            object.fetch("current_period_end")
          end
          record.update!(
            name: record.name.presence || object.dig("metadata", "pay_subscription_name").presence || Pay.default_product_name,
            processor_plan: object.fetch("variant_id"), quantity: 1, status: status,
            pause_starts_at: (object["most_recent_action"] == "paused_at") ? Whop.timestamp(object["current_period_end"]) : nil,
            current_period_start: Whop.timestamp(object["current_period_start"]),
            current_period_end: Whop.timestamp(object["current_period_end"]),
            trial_ends_at: (status == "trialing") ? Whop.timestamp(object["current_period_end"]) : nil,
            ends_at: Whop.timestamp(ends_at),
            data: record.data.to_h.merge("whop_updated_at" => source_time.iso8601(6), "manage_url" => object["manage_url"], "whop_billing_paused" => object["most_recent_action"] == "paused_at")
          )
          record
        end
      end

      def sync!(**options)
        customer.verify_configuration!
        self.class.sync(processor_id, **options, account_id: customer.account_id)
        reload
      end

      def api_record
        customer.verify_configuration!
        result = Whop.api.memberships.retrieve(id: processor_id, request_options: Whop.request_options)
        customer.verify_resource!(Whop.api_attributes(result))
        result
      end

      def portal_url = data.to_h["manage_url"]
      def whop? = true
      def paused? = data.to_h["whop_billing_paused"] == true

      def active?
        return on_trial? if status == "trialing"
        return super unless paused?
        %w[active trialing].include?(status) && current_period_end.present? && current_period_end.future? && (ends_at.nil? || ends_at.future?)
      end

      def resumable? = paused? || (canceled? && on_grace_period?)

      def cancel(idempotency_key: SecureRandom.uuid)
        cancel_membership(true, idempotency_key)
      end

      def cancel_now!(idempotency_key: SecureRandom.uuid)
        cancel_membership(false, idempotency_key)
      end

      def resume(idempotency_key: SecureRandom.uuid)
        return unpause(idempotency_key: idempotency_key) if paused?
        customer.verify_configuration!
        raise Error, "Only a scheduled cancellation can be resumed" unless resumable?
        Whop.api.memberships.update(id: processor_id, cancel_at_period_end: false, request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      def pause(until_time: nil, idempotency_key: SecureRandom.uuid)
        customer.verify_configuration!
        Whop.api.memberships.pause(id: processor_id, until: until_time&.iso8601,
          request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      def unpause(idempotency_key: SecureRandom.uuid)
        customer.verify_configuration!
        Whop.api.memberships.resume(id: processor_id, request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      def reactivate(**options)
        raise Pay::NotSupportedError, "Whop only reactivates one-time memberships; start a new checkout for an ended recurring subscription"
      end

      def extend_trial(days, idempotency_key: SecureRandom.uuid)
        customer.verify_configuration!
        raise ArgumentError, "Days must be between 1 and 1095" unless days.is_a?(Integer) && (1..1095).cover?(days)
        Whop.api.memberships.extend_(id: processor_id, days: days, request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end
      alias_method :add_free_days, :extend_trial

      def update_payment_method(payment_method_id, idempotency_key: SecureRandom.uuid)
        customer.add_payment_method(payment_method_id)
        Whop.api.memberships.update(id: processor_id, payment_method_id: payment_method_id,
          request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      def apply_promo_code(promo_code:, idempotency_key: SecureRandom.uuid)
        customer.verify_configuration!
        Whop.api.memberships.apply_promo_code(id: processor_id, promo_code: promo_code,
          request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      def latest_payment
        api_record
        payment = Whop.api.payments.list(account_id: customer.account_id, member_id: customer.processor_id,
          membership_id: processor_id, order: "created_at", direction: "desc", first: 1, request_options: Whop.request_options).first
        return unless payment
        object = Whop.api_attributes(payment)
        customer.verify_resource!(object)
        raise IdentityError, "Payment belongs to another membership" unless object["membership_id"] == processor_id
        customer.payment(object.fetch("id"))
      end

      def retry_failed_payment(payment_id: nil, idempotency_key: SecureRandom.uuid)
        payment = payment_id ? customer.payment(payment_id) : latest_payment
        raise Error, "No membership payment is available to retry" unless payment
        object = Whop.api_attributes(payment)
        raise IdentityError, "Payment belongs to another membership" unless object["membership_id"] == processor_id
        return Charge.sync(payment.id, account_id: customer.account_id) if payment.status == "paid"
        customer.retry_payment(payment.id, idempotency_key: idempotency_key)
      end

      def reduce_renewal_price(amount, decimals: nil, idempotency_key: SecureRandom.uuid)
        object = Whop.api_attributes(api_record)
        price = object.fetch("renewal_price")
        precision = price.fetch("decimals")
        raise ArgumentError, "Precision must match the renewal currency" if decimals && decimals != precision
        value = Whop.major_units(amount, decimals: precision)
        raise ArgumentError, "Renewal price can only be reduced" unless amount < Whop.minor_units(price)
        update_renewal({renewal_price: value}, idempotency_key)
      end

      def change_billing_period(days, idempotency_key: SecureRandom.uuid)
        raise ArgumentError, "Billing period must be between 1 and 365 days" unless days.is_a?(Integer) && (1..365).cover?(days)
        api_record
        update_renewal({billing_period_days: days}, idempotency_key)
      end

      def change_next_renewal(at, idempotency_key: SecureRandom.uuid)
        raise ArgumentError, "Next renewal must be after today in UTC" unless at.respond_to?(:utc) && at.utc.to_date > Time.current.utc.to_date
        api_record
        update_renewal({current_period_end: at.utc.iso8601}, idempotency_key)
      end

      %i[swap change_quantity].each do |operation|
        define_method(operation) do |*args, **options|
          raise Pay::NotSupportedError, "#{operation} is not supported by pay-whop yet"
        end
      end

      private

      def update_renewal(attributes, key)
        Whop.api_request(:patch, "memberships/#{ERB::Util.url_encode(processor_id)}", body: attributes, idempotency_key: key)
        sync!
      end

      def cancel_membership(at_period_end, key)
        customer.verify_configuration!
        Whop.api.memberships.cancel(id: processor_id, cancel_at_period_end: at_period_end, request_options: Whop.request_options(idempotency_key: key))
        sync!
      end
    end
  end
end
