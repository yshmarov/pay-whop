class RecoverDeliveriesJob < ActiveJob::Base
  def perform
    Pay::Whop::Delivery.pending.where(created_at: 1.day.ago..2.minutes.ago).find_each do |delivery|
      Pay::Whop::ProcessDeliveryJob.perform_later(delivery)
    end
  end
end
