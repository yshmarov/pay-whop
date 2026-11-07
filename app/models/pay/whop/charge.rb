module Pay
  module Whop
    class Charge < Pay::Charge
      def self.sync(id)
        object = Whop.api_attributes(Whop.client.payments.retrieve(id: id, request_options: Whop.request_options))
        raise InvalidPayload, "Unexpected payment ID" unless object.fetch("id") == id
        Whop.verify_account!(object)
        subscription = Subscription.sync(object["membership_id"]) if object["membership_id"].present?
        return unless object.fetch("status") == "paid"
        customer = Customer.resolve!(object)
        if subscription && subscription.customer_id != customer.id
          raise IdentityError, "Payment and membership belong to different customers"
        end
        customer.with_lock do
          record = customer.charges.find_or_initialize_by(processor_id: id)
          source_time = Whop.timestamp(object.fetch("updated_at"))
          saved_time = Whop.timestamp(record.data.to_h["whop_updated_at"])
          return record if saved_time && saved_time > source_time
          total = object.fetch("total")
          currency = total.fetch("currency").downcase
          refunded = object["refunded_amount"]
          record.update!(
            amount: Whop.minor_units(total), currency: currency,
            amount_refunded: refunded ? Whop.minor_units(refunded, currency: currency) : 0,
            subscription: subscription,
            created_at: Whop.timestamp(object["paid_at"] || object.fetch("created_at")),
            data: record.data.to_h.merge("whop_updated_at" => source_time.iso8601(6), "payment_method_type" => object["payment_method_type"])
          )
          record
        end
      end

      def api_record
        customer.verify_configuration!
        Whop.client.payments.retrieve(id: processor_id, request_options: Whop.request_options)
      end

      def refund!(amount_to_refund = nil, idempotency_key: SecureRandom.uuid)
        customer.verify_configuration!
        if amount_to_refund && amount_to_refund != amount - amount_refunded.to_i
          raise Pay::NotSupportedError, "pay-whop currently supports refunding the remaining balance only"
        end
        Whop.client.payments.refund(id: processor_id, request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      def whop? = true
    end
  end
end
