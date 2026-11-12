module Pay
  module Whop
    class PaymentMethod < Pay::PaymentMethod
      def self.sync(object, customer:)
        customer.verify_configuration!
        customer.with_lock do
          method = customer.payment_methods.find_or_initialize_by(processor_id: object.fetch("id"))
          method.update!(payment_method_type: object.fetch("payment_method_type"),
            data: (object["card"] || {}).slice("brand", "last4", "exp_month", "exp_year"))
          method
        end
      end

      def make_default!
        customer.verify_configuration!
        customer.with_lock do
          customer.payment_methods.update_all(default: false)
          update!(default: true)
        end
      end

      def detach
        customer.sync_payment_methods
        raise IdentityError, "Payment method is no longer owned by this customer" unless self.class.exists?(id)
        Whop.api.payment_methods.delete_payment_method(id: processor_id, request_options: Whop.request_options(idempotency_key: "pay-whop-detach-#{id}"))
        destroy!
      end

      def self.sync_setup(id, account_id:)
        object = Whop.api_attributes(Whop.api.setup_intents.retrieve(id: id, request_options: Whop.request_options))
        raise InvalidPayload, "Unexpected setup intent ID" unless object.fetch("id") == id
        Whop.verify_account!(object, expected: account_id)
        return unless object["status"] == "succeeded"
        customer = Customer.resolve!(object)
        customer.add_payment_method(object.fetch("payment_method_id"))
      end

      def whop? = true
    end
  end
end
