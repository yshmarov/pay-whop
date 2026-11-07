module Pay
  module Whop
    class ProcessDeliveryJob < ActiveJob::Base
      queue_as { Whop.queue_name }
      retry_on ::Whop_sdk::Errors::ApiError, wait: :polynomially_longer, attempts: 5
      retry_on ActiveRecord::Deadlocked, ActiveRecord::RecordNotUnique, wait: 2.seconds, attempts: 5

      def perform(delivery)
        delivery.process!
      end
    end
  end
end
