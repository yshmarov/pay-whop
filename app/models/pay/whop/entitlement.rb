module Pay
  module Whop
    class Entitlement < Resource
      def self.sync(id, account_id:)
        object = Whop.api_attributes(Whop.api.memberships.retrieve(id: id, request_options: Whop.request_options))
        raise InvalidPayload, "Unexpected membership ID" unless object.fetch("id") == id
        sync_object(object, account_id: account_id)
      end

      def self.sync_object(object, account_id:)
        Whop.verify_account!(object, expected: account_id)
        raise InvalidPayload, "Recurring memberships are subscriptions" if object["renewal_price"].present?
        customer = Customer.resolve!(object)
        persist_snapshot(object, account_id: account_id, owner: customer,
          attributes: {data: object.slice("product_id", "variant_id", "expires_at", "current_period_end", "manage_url")})
      end

      def active?
        expiry = Whop.timestamp(data.to_h["expires_at"])
        %w[completed active trialing].include?(status) && (expiry.nil? || expiry.future?)
      end

      def reactivate(days: nil, idempotency_key: SecureRandom.uuid)
        verify_configuration!
        Whop.api.memberships.reactivate(id: processor_id, days: days, request_options: Whop.request_options(idempotency_key: idempotency_key))
        sync!
      end
    end
  end
end
