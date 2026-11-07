module Pay
  module Whop
    class Delivery < Pay::ApplicationRecord
      self.table_name = "pay_whop_deliveries"

      EVENTS = %w[payment.succeeded payment.failed payment.pending payment.canceled membership.activated membership.deactivated membership.updated refund.created refund.updated payment.authorized payment.requires_action setup_intent.succeeded setup_intent.canceled setup_intent.requires_action invoice.created invoice.paid invoice.past_due invoice.voided invoice.marked_uncollectible dispute.created dispute.updated transfer.created transfer.completed transfer.failed membership.cancel_at_period_end_changed account.updated].freeze

      scope :pending, -> { where(processed_at: nil) }

      def process!
        return if processed_at?
        unless environment == Whop.environment
          raise IdentityError, "Webhook belongs to another Whop account or environment"
        end
        Whop.verify_account!({"account_id" => account_id})
        case event_type
        when /\Amembership\./
          Subscription.sync(resource_id, account_id: account_id)
        when "account.updated"
          Merchant.sync(resource_id, account_id: account_id) unless resource_id == Whop.account_id
        when /\Asetup_intent\./
          PaymentMethod.sync_setup(resource_id, account_id: account_id)
        when /\Ainvoice\./
          Invoice.sync(resource_id, account_id: account_id)
        when /\Adispute\./
          Dispute.sync(resource_id, account_id: account_id)
        when /\Atransfer\./
          Transfer.sync(resource_id, account_id: account_id)
        else
          Charge.sync(resource_id, account_id: account_id)
        end
        update!(processed_at: Time.current)
      end
    end
  end
end
