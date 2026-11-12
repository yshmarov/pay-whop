module Pay
  module Whop
    class Resource < Pay::ApplicationRecord
      self.table_name = "pay_whop_resources"
      belongs_to :customer, class_name: "Pay::Whop::Customer", optional: true
      belongs_to :merchant, class_name: "Pay::Whop::Merchant", optional: true

      def self.persist_snapshot(object, account_id:, owner:, attributes:)
        raise IdentityError, "Resource account is not registered" unless Whop.verify_account!({"account_id" => account_id})
        owner.with_lock do
          record = find_or_initialize_by(processor_id: object.fetch("id"), account_id: account_id, environment: Whop.environment)
          time = Whop.timestamp(object["updated_at"])
          previous = Whop.timestamp(record.data.to_h["whop_updated_at"])
          return record if time && previous && previous > time
          if self == Transfer && record.persisted? && %w[succeeded failed].include?(record.status)
            return record if object["status"] == "processing"
            raise InvalidPayload, "Conflicting final transfer state" if object["status"] != record.status
          end
          if self == Payout && record.persisted? && %w[completed reversed failed denied canceled].include?(record.status)
            return record if %w[requested in_review processing].include?(object["status"])
          end
          owner_key = owner.is_a?(Merchant) ? :merchant : :customer
          if record.persisted? && record.public_send("#{owner_key}_id") != owner.id
            raise IdentityError, "Resource owner changed"
          end
          record.update!(**attributes, owner_key => owner, :status => object.fetch("status"),
            :data => attributes.fetch(:data, {}).merge("whop_updated_at" => time&.iso8601(6)))
          record
        end
      end

      def verify_configuration!
        raise IdentityError, "Resource belongs to another environment" unless environment == Whop.environment
        Whop.verify_account!({"account_id" => account_id})
        customer&.verify_configuration!
        raise IdentityError, "Resource belongs to another customer account" if customer && customer.account_id != account_id
        merchant&.verify_configuration!
      end

      def sync!
        verify_configuration!
        self.class.sync(processor_id, account_id: account_id)
        reload
      end
    end
  end
end
