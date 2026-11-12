module Pay
  module Whop
    class ProcessDeliveryJob < ActiveJob::Base
      queue_as { Whop.queue_name }
      retry_on ApiError, wait: :polynomially_longer, attempts: 5 do |job, error|
        job.report_failure(error)
      end
      retry_on ActiveRecord::Deadlocked, ActiveRecord::RecordNotUnique, wait: 2.seconds, attempts: 5

      def perform(delivery)
        delivery.process!
      rescue ApiError => error
        raise if error.retryable?
        report_failure(error)
      end

      def report_failure(error)
        ActiveSupport::Notifications.instrument("delivery_failed.pay_whop", delivery_id: arguments.first.id, status: error.status, code: error.code)
      end
    end
  end
end
