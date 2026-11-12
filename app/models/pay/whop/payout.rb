module Pay
  module Whop
    class Payout < Resource
      def self.sync(id, account_id:)
        Whop.validate_configuration!
        merchant = Merchant.find_by!(processor_id: account_id) unless account_id == Whop.account_id
        merchant&.verify_configuration!
        Whop.each_api_page("payouts", account_id: account_id) do |object|
          return sync_object(object, merchant: merchant, account_id: account_id) if object.fetch("id") == id || object["payout_request_id"] == id
        end
        raise IdentityError, "Payout is not owned by this merchant"
      end

      def self.sync_object(object, merchant: nil, account_id: merchant&.processor_id || Whop.account_id)
        Whop.validate_configuration!
        merchant&.verify_configuration!
        unless account_id == (merchant&.processor_id || Whop.account_id)
          raise IdentityError, "Payout account is not registered"
        end
        if object["account_id"].present? && object["account_id"] != account_id
          raise IdentityError, "Payout belongs to another account"
        end
        attributes = {currency: object["currency"], data: object.slice("amount", "fee_amount", "net_amount", "fee_paid_by", "payout_request_id", "estimated_arrival", "status_detail", "created_at")}
        return persist_snapshot(object, account_id: account_id, owner: merchant, attributes: attributes) if merchant

        record = create_or_find_by!(processor_id: object.fetch("id"), account_id: account_id, environment: Whop.environment) do |payout|
          payout.assign_attributes(**attributes, status: object.fetch("status"))
        end
        record.with_lock do
          raise IdentityError, "Platform payout has an unexpected owner" if record.customer_id || record.merchant_id
          return record if record.status == "reversed" && object["status"] != "reversed"
          return record if %w[completed reversed failed denied canceled].include?(record.status) && %w[requested in_review processing].include?(object["status"])
          record.update!(**attributes, status: object.fetch("status"))
        end
        record
      end
    end
  end
end
