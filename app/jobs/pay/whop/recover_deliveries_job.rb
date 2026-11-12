module Pay
  module Whop
    class RecoverDeliveriesJob < ActiveJob::Base
      queue_as { Whop.queue_name }

      def perform(older_than: 2.minutes.ago, since: nil)
        scope = Delivery.pending.where(created_at: ..older_than)
        scope = scope.where(created_at: since..) if since
        scope.find_each { |delivery| ProcessDeliveryJob.perform_later(delivery) }
      end
    end
  end
end
