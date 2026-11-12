module Pay
  module Whop
    class Transfer < Resource
      def self.sync(id, account_id:)
        object = Whop.api_attributes(Whop.api.transfers.retrieve(id: id, request_options: Whop.request_options))
        raise InvalidPayload, "Unexpected transfer ID" unless object.fetch("id") == id
        destination = object.fetch("destination").fetch("id")
        unless object.dig("origin", "id") == Whop.account_id && [Whop.account_id, destination].include?(account_id)
          raise IdentityError, "Transfer is outside this platform"
        end
        merchant = Merchant.find_by!(processor_id: destination)
        merchant.verify_configuration!
        total = object["amount"].presence
        persist_snapshot(object, account_id: Whop.account_id, owner: merchant,
          attributes: {amount: total && Whop.minor_units(total), currency: total && total.fetch("currency"),
                       data: {"origin_id" => Whop.account_id, "destination_id" => destination}})
      end
    end
  end
end
