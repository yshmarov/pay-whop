require "test_helper"

class WebhooksTest < ActionDispatch::IntegrationTest
  test "signature-verified events persist only IDs and duplicate deliveries do not duplicate records" do
    body, headers = sign_event
    assert_enqueued_with(job: Pay::Whop::ProcessDeliveryJob) do
      post "/pay/whop/webhooks", params: body, headers: headers
    end
    assert_response :ok
    delivery = Pay::Whop::Delivery.sole
    assert_equal "pay_test", delivery.resource_id
    assert_not delivery.attributes.key?("data")
    post "/pay/whop/webhooks", params: body, headers: headers
    assert_response :ok
    assert_equal 1, Pay::Whop::Delivery.count
    api(:get, "payments/pay_test", payment)
    delivery.process!
    assert delivery.processed_at?
    assert_no_enqueued_jobs do
      post "/pay/whop/webhooks", params: body, headers: headers
    end
  end

  test "invalid signatures and stale signatures create no deliveries" do
    body, headers = sign_event
    post "/pay/whop/webhooks", params: body + " ", headers: headers
    assert_response :bad_request
    body, headers = sign_event(at: Time.now - 600)
    post "/pay/whop/webhooks", params: body, headers: headers
    assert_response :bad_request
    assert_empty Pay::Whop::Delivery.all
  end

  test "wrong account is rejected even with a valid signature" do
    body, headers = sign_event(account: "biz_other")
    post "/pay/whop/webhooks", params: body, headers: headers
    assert_response :bad_request
    assert_empty Pay::Whop::Delivery.all
  end

  test "refund webhook reconciles the payment rather than treating the refund ID as a charge" do
    body, headers = sign_event(type: "refund.updated", data: {"id" => "rf_test", "payment_id" => "pay_test"})
    post "/pay/whop/webhooks", params: body, headers: headers
    assert_response :ok
    assert_equal "pay_test", Pay::Whop::Delivery.sole.resource_id
  end

  test "API failure leaves the delivery available for retry" do
    body, headers = sign_event
    post "/pay/whop/webhooks", params: body, headers: headers
    delivery = Pay::Whop::Delivery.sole
    api(:get, "payments/pay_test", {error: "unavailable"}, status: 503)
    assert_raises(Whop_sdk::Errors::ApiError) { delivery.process! }
    assert_nil delivery.reload.processed_at
    api(:get, "payments/pay_test", payment)
    delivery.process!
    assert delivery.reload.processed_at?
  end
  test "reusing an event ID with a different resource is rejected" do
    body, headers = sign_event
    post "/pay/whop/webhooks", params: body, headers: headers
    body, headers = sign_event(data: {"id" => "pay_other"})
    post "/pay/whop/webhooks", params: body, headers: headers
    assert_response :bad_request
    assert_equal "pay_test", Pay::Whop::Delivery.sole.resource_id
  end

  test "enqueue refusal returns a retryable response and retains the event" do
    body, headers = sign_event
    Pay::Whop::ProcessDeliveryJob.stub(:perform_later, false) do
      post "/pay/whop/webhooks", params: body, headers: headers
    end
    assert_response :service_unavailable
    assert_nil Pay::Whop::Delivery.sole.processed_at
  end
end
