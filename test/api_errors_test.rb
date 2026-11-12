require "test_helper"

class ApiErrorsTest < ActiveSupport::TestCase
  test "SDK errors retain status and type through the Pay error contract" do
    api(:get, "members/mber_test", {error: {type: "forbidden", message: "Permission required"}}, status: 403)
    @customer.update!(processor_id: "mber_test")
    error = assert_raises(Pay::Error) { @customer.api_record }
    assert_equal 403, error.status
    assert_equal "forbidden", error.code
    assert_equal "Permission required", error.message
    assert_not error.retryable?
    assert_instance_of Whop_sdk::Errors::ForbiddenError, error.provider_error
    assert_equal error.provider_error, error.cause
  end

  test "lazy pagination errors are normalized without deleting saved methods" do
    @customer.update!(processor_id: "mber_test")
    method = @customer.payment_methods.create!(processor_id: "payt_test", type: "Pay::Whop::PaymentMethod", payment_method_type: "card", default: true)
    api(:get, "payment_methods?member_id=mber_test&first=100&after", {error: {type: "unavailable"}}, status: 503)
    error = assert_raises(Pay::Whop::ApiError) { @customer.sync_payment_methods }
    assert error.retryable?
    assert method.reload.default?
  end

  test "malformed provider error bodies do not leak credentials or bypass normalization" do
    ["[]", "null", "private server error test_api_key"].each do |body|
      original = Whop_sdk::Errors::ServerError.new(body, code: 502)
      error = assert_raises(Pay::Whop::ApiError) { Pay::Whop.with_api_errors { raise original } }
      assert_equal "Whop request failed (HTTP 502)", error.message
      assert error.retryable?
    end
  end

  test "raw HTTP timeout has the same error contract and no automatic replay" do
    request = stub_request(:post, "https://sandbox-api.whop.com/api/v1/transfers").to_timeout
    error = assert_raises(Pay::Whop::ApiError) { Pay::Whop.api_request(:post, "transfers", body: {}, idempotency_key: "transfer-test") }
    assert error.retryable?
    assert_nil error.status
    assert_requested request, times: 1
  end
end
