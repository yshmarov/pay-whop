module Pay
  module Whop
    class Delivery < Pay::ApplicationRecord
      self.table_name = "pay_whop_deliveries"

      EVENTS = %w[payment.succeeded payment.failed payment.pending payment.canceled membership.activated membership.deactivated membership.updated refund.created refund.updated].freeze

      scope :pending, -> { where(processed_at: nil) }

      def process!
        return if processed_at?
        unless [account_id, environment] == [Whop.account_id, Whop.environment]
          raise IdentityError, "Webhook belongs to another Whop account or environment"
        end
        case event_type
        when /\Amembership\./
          Subscription.sync(resource_id)
        else
          Charge.sync(resource_id)
        end
        update!(processed_at: Time.current)
      end
    end
  end
end
