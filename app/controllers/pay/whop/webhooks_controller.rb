module Pay
  module Whop
    class WebhooksController < ActionController::API
      def create
        raise ConfigurationError, "Set Pay::Whop.webhook_secret" if Whop.webhook_secret.blank?
        event = ::WhopSDK::Helpers::VerifyWebhook.unwrap(request.raw_post,
          headers: %w[webhook-id webhook-timestamp webhook-signature].to_h { |name| [name, request.headers[name]] },
          key: Whop.webhook_secret).deep_stringify_keys
        account = Whop.verify_account!(event)
        return head :ok unless Delivery::EVENTS.include?(event["type"])
        raise InvalidPayload, "Webhook ID mismatch" unless event.fetch("id") == request.headers["webhook-id"]
        object = event.fetch("data")
        resource_id = event["type"].start_with?("refund.") ? refund_payment_id(object) : object.fetch("id")
        raise InvalidPayload, "Missing resource ID" if resource_id.blank?
        delivery = Delivery.create_or_find_by!(environment: Whop.environment, account_id: account, event_id: event.fetch("id")) do |record|
          record.event_type = event.fetch("type")
          record.resource_id = resource_id
        end
        unless delivery.event_type == event["type"] && delivery.resource_id == resource_id
          raise InvalidPayload, "Webhook ID reused for a different event"
        end
        unless delivery.processed_at?
          return head :service_unavailable unless ProcessDeliveryJob.perform_later(delivery)
        end
        head :ok
      rescue ::StandardWebhooks::WebhookVerificationError, JSON::ParserError, KeyError, IdentityError, InvalidPayload
        head :bad_request
      end

      private

      def refund_payment_id(object)
        payment = object["payment"]
        raise InvalidPayload, "Invalid refund payment" unless payment.nil? || payment.is_a?(Hash)
        ids = [object["payment_id"], payment&.dig("id")].compact.uniq
        raise InvalidPayload, "Missing or conflicting refund payment IDs" unless ids.one? && ids.first.is_a?(String) && ids.first.present?
        ids.first
      end
    end
  end
end
