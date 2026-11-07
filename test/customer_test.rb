require "test_helper"

class CustomerTest < ActiveSupport::TestCase
  test "Pay selects the community adapter and checkout attaches a signed customer reference" do
    request = api(:post, "checkout_configurations", {id: "ch_test", purchase_url: "https://sandbox.whop.com/checkout/test"})
      .with { |req|
        body = JSON.parse(req.body)
        token = body.dig("metadata", "pay_customer")
        Pay::Whop::Customer.find_signed(token, purpose: Pay::Whop.identity_purpose) == @customer &&
          body["account_id"] == "biz_test" && body["variant_id"] == "plan_test" &&
          req.headers["Idempotency-Key"] == "checkout-attempt-1"
      }
    result = @user.payment_processor.checkout(variant_id: "plan_test", redirect_url: "https://example.test/billing", idempotency_key: "checkout-attempt-1")
    assert_equal "https://sandbox.whop.com/checkout/test", result.purchase_url
    assert_requested request
  end

  test "checkout cannot cross environments" do
    Pay::Whop.environment = "production"
    assert_raises(Pay::Whop::IdentityError) { @customer.checkout(variant_id: "plan_test", redirect_url: "https://example.test") }
  end

  test "a member cannot be reassigned to another owner" do
    Pay::Whop::Customer.resolve!(payment)
    other = User.create!(email: "other@example.test").set_payment_processor(:whop, data: @customer.data)
    object = payment(metadata: {"pay_customer" => other.signed_id(purpose: Pay::Whop.identity_purpose)})
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Customer.resolve!(object) }
    assert_equal "mber_test", @customer.reload.processor_id
    assert_nil other.reload.processor_id
  end

  test "an invalid token never falls back to matching a member" do
    @customer.update!(processor_id: "mber_test")
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Customer.resolve!(payment(metadata: {"pay_customer" => "forged"})) }
  end
end
