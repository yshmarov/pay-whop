module Pay
  module Whop
    class Charge < Pay::Charge
      def self.sync(id, account_id: nil)
        object = Whop.api_attributes(Whop.api.payments.retrieve(id: id, request_options: Whop.request_options))
        raise InvalidPayload, "Unexpected payment ID" unless object.fetch("id") == id
        Whop.verify_account!(object, expected: account_id)
        subscription = Subscription.sync(object["membership_id"], account_id: object["account_id"]) if object["membership_id"].present?
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
            data: record.data.to_h.merge("whop_updated_at" => source_time.iso8601(6), "payment_method_type" => object["payment_method_type"], "whop_decimals" => total.fetch("decimals"))
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
        customer.payment(processor_id)
      end

      def refund!(amount_to_refund = nil, idempotency_key: SecureRandom.uuid)
        customer.verify_configuration!
        object = Whop.api_attributes(api_record)
        customer.verify_resource!(object)
        total = object.fetch("total")
        remaining = Whop.minor_units(total) - Whop.minor_units(object.fetch("refunded_amount"), currency: total.fetch("currency"))
        raise Error, "Payment is already fully refunded" unless remaining.positive?
        body = {}
        if amount_to_refund
          raise ArgumentError, "Refund exceeds remaining balance" if amount_to_refund > remaining
          body = {partial_amount: Whop.major_units(amount_to_refund, decimals: total.fetch("decimals"))}
        end
        Whop.api_request(:post, "payments/#{ERB::Util.url_encode(processor_id)}/refund", body: body, idempotency_key: idempotency_key)
        sync!
      end

      def fees
        api_record
        Whop.api.payments.list_fees(id: processor_id, request_options: Whop.request_options)
      end

      def whop? = true
    end
  end
end
