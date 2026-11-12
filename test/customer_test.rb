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

  test "opted in shared buyers resolve only the signed customer without reassigning either owner" do
    Pay::Whop.allow_shared_members = true
    Pay::Whop::Customer.resolve!(payment)
    other = User.create!(email: "shared@example.test").set_payment_processor(:whop, data: @customer.data)
    object = payment(metadata: {"pay_customer" => other.signed_id(purpose: Pay::Whop.identity_purpose)})
    assert_equal other, Pay::Whop::Customer.resolve!(object)
    assert_equal "mber_test", @customer.reload.processor_id
    assert_equal "mber_test", other.reload.processor_id
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Customer.resolve!(payment(metadata: {})) }
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Customer.resolve!(payment(metadata: {"pay_customer" => "forged"})) }
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Customer.resolve!(object.merge("member_id" => "mber_other")) }
  end
  test "shared buyer subscription lists never import another organizations membership" do
    Pay::Whop.allow_shared_members = true
    @customer.update!(processor_id: "mber_test")
    other = User.create!(email: "shared-lists@example.test").set_payment_processor(:whop, data: @customer.data)
    other.update!(processor_id: "mber_test")
    foreign = membership(id: "mem_other", metadata: other.checkout_metadata)
    api(:get, "memberships?account_id=biz_test&member_id=mber_test&first=100&after", {data: [membership, foreign], page_info: {has_next_page: false}})
    api(:get, "memberships/mem_test", membership)
    @customer.sync_subscriptions
    assert_equal "mem_test", @customer.subscriptions.sole.processor_id
    assert_empty other.subscriptions
    assert_not_requested :get, "https://sandbox-api.whop.com/api/v1/memberships/mem_other"
    %w[payments invoices].each do |endpoint|
      api(:get, "#{endpoint}?account_id=biz_test&member_id=mber_test&first=100&after", {data: [], page_info: {has_next_page: false}})
    end
    assert_equal({memberships: 1, payments: 0, invoices: 0, skipped: 1}, @customer.reconcile!)
    assert_empty other.subscriptions
  end
end
