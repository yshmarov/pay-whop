module Pay
  module Whop
    class Dispute < Resource
      def self.sync(id, account_id:)
        object = Whop.api_attributes(Whop.api.disputes.retrieve(id: id, request_options: Whop.request_options))
        raise InvalidPayload, "Unexpected dispute ID" unless object.fetch("id") == id
        Whop.verify_account!(object, expected: account_id)
        payment_id = object.fetch("payment").fetch("id")
        charge = Charge.sync(payment_id, account_id: account_id)
        raise InvalidPayload, "Dispute payment is not a confirmed charge" unless charge
        persist_snapshot(object, account_id: account_id, owner: charge.customer,
          attributes: {currency: object["currency"], data: object.slice("reason", "evidence_due_at", "evidence_editable", "acceptable", "submission_failure_reason").merge("payment_id" => payment_id)})
      end

      def update_evidence(evidence:, idempotency_key: SecureRandom.uuid)
        verify_configuration!
        Whop.api.disputes.update(id: processor_id, evidence: evidence, request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      def upload_evidence(documents:, idempotency_key: SecureRandom.uuid)
        verify_configuration!
        Whop.api.disputes.upload_evidence(id: processor_id, documents: documents,
          request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end

      %i[submit accept].each do |operation|
        define_method(operation) do |idempotency_key: SecureRandom.uuid|
          verify_configuration!
          Whop.api.disputes.public_send(operation, id: processor_id, request_options: Whop.request_options(idempotency_key: idempotency_key))
          sync!
        end
      end
    end
  end
end
