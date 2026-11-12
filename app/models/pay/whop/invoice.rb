module Pay
  module Whop
    class Invoice < Resource
      def self.sync(id, account_id:)
        object = Whop.api_attributes(Whop.api.invoices.retrieve(id: id, request_options: Whop.request_options))
        raise InvalidPayload, "Unexpected invoice ID" unless object.fetch("id") == id
        Whop.verify_account!(object, expected: account_id)
        customer = Customer.resolve!(object)
        total = object.fetch("total")
        record = persist_snapshot(object, account_id: account_id, owner: customer, attributes: {
          amount: Whop.minor_units(total), currency: total.fetch("currency"),
          data: object.slice("checkout_link", "number", "due_at", "paid_at", "overdue", "membership_id")
        })
        Charge.sync(id, account_id: account_id) if object["status"] == "paid"
        record
      end

      def checkout_url = data.to_h["checkout_link"]

      def issue(charge_at: nil, idempotency_key: SecureRandom.uuid)
        verify_configuration!
        Whop.api.invoices.issue(id: processor_id, charge_at: charge_at&.iso8601, request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      %i[void mark_uncollectible unschedule].each do |operation|
        define_method(operation) do |idempotency_key: SecureRandom.uuid|
          verify_configuration!
          Whop.api.invoices.public_send(operation, id: processor_id, request_options: Whop.request_options(idempotency_key: idempotency_key))
          sync!
        end
      end

      def charge(payment_method_id: nil, idempotency_key: SecureRandom.uuid)
        verify_configuration!
        customer.add_payment_method(payment_method_id) if payment_method_id
        Whop.api_request(:post, "invoices/#{ERB::Util.url_encode(processor_id)}/charge",
          body: {payment_method_id: payment_method_id}.compact, idempotency_key: idempotency_key)
        sync!
      end

      def deliver(idempotency_key: SecureRandom.uuid)
        verify_configuration!
        Whop.api.invoices.send_(id: processor_id, request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      def update_details(memo: nil, due_at: nil, idempotency_key: SecureRandom.uuid)
        verify_configuration!
        Whop.api.invoices.update(id: processor_id, memo: memo, due_at: due_at&.iso8601,
          request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      def pdf_url
        verify_configuration!
        Whop.api.invoices.generate_pdf(id: processor_id, request_options: Whop.request_options).url
      end
    end
  end
end
