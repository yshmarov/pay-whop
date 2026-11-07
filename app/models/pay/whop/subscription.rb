module Pay
  module Whop
    class Subscription < Pay::Subscription
      def self.sync(id)
        object = Whop.api_attributes(Whop.client.memberships.retrieve(id: id, request_options: Whop.request_options))
        raise InvalidPayload, "Unexpected membership ID" unless object.fetch("id") == id
        customer = Customer.resolve!(object)
        return unless object["renewal_price"].present?
        customer.with_lock do
          record = customer.subscriptions.find_or_initialize_by(processor_id: id)
          source_time = Whop.timestamp(object.fetch("updated_at"))
          saved_time = Whop.timestamp(record.data.to_h["whop_updated_at"])
          return record if saved_time && saved_time > source_time
          status = object.fetch("status")
          status = {"drafted" => "incomplete", "unresolved" => "incomplete", "canceling" => "active", "expired" => "canceled"}.fetch(status, status)
          ends_at = if object["cancel_at_period_end"]
            object.fetch("current_period_end")
          elsif %w[canceled expired].include?(object["status"])
            object["canceled_at"] || object["expires_at"] || object.fetch("updated_at")
          end
          record.update!(
            name: record.name.presence || object.dig("metadata", "pay_subscription_name").presence || Pay.default_product_name,
            processor_plan: object.fetch("variant_id"), quantity: 1, status: status,
            current_period_start: Whop.timestamp(object["current_period_start"]),
            current_period_end: Whop.timestamp(object["current_period_end"]),
            trial_ends_at: (status == "trialing") ? Whop.timestamp(object["current_period_end"]) : nil,
            ends_at: Whop.timestamp(ends_at),
            data: record.data.to_h.merge("whop_updated_at" => source_time.iso8601(6), "manage_url" => object["manage_url"])
          )
          record
        end
      end

      def api_record
        customer.verify_configuration!
        Whop.client.memberships.retrieve(id: processor_id, request_options: Whop.request_options)
      end

      def portal_url = data.to_h["manage_url"]
      def whop? = true
      def paused? = false
      def resumable? = canceled? && on_grace_period?

      def cancel(idempotency_key: SecureRandom.uuid)
        cancel_membership(true, idempotency_key)
      end

      def cancel_now!(idempotency_key: SecureRandom.uuid)
        cancel_membership(false, idempotency_key)
      end

      def resume(idempotency_key: SecureRandom.uuid)
        customer.verify_configuration!
        raise Error, "Only a scheduled cancellation can be resumed" unless resumable?
        Whop.client.memberships.update(id: processor_id, cancel_at_period_end: false, request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      %i[swap change_quantity pause].each do |operation|
        define_method(operation) do |*args, **options|
          raise Pay::NotSupportedError, "#{operation} is not supported by pay-whop yet"
        end
      end

      private

      def cancel_membership(at_period_end, key)
        customer.verify_configuration!
        Whop.client.memberships.cancel(id: processor_id, cancel_at_period_end: at_period_end, request_options: Whop.request_options(idempotency_key: key))
        sync!
      end
    end
  end
end
