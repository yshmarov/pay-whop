require "test_helper"

class MarketplaceTest < ActionDispatch::IntegrationTest
  def merchant(account_id = "biz_seller")
    @merchant ||= @user.set_merchant_processor(:whop, processor_id: account_id,
      data: {whop_platform_id: "biz_test", whop_environment: "sandbox"})
  end

  def seller_payment(customer, **changes)
    payment(account_id: "biz_seller", member_id: "mber_seller", metadata: customer.checkout_metadata, **changes)
  end

  test "seller customer is distinct and never changes the default processor" do
    seller = merchant.customer_for(@user)
    assert_not_equal @customer.id, seller.id
    assert_equal @customer.id, @user.reload.payment_processor.id
    assert_equal seller.id, merchant.customer_for(@user).id
    assert_equal "biz_seller", seller.account_id
  end

  test "subaccount creation verifies its parent before registration" do
    record = @user.set_merchant_processor(:whop)
    api(:post, "accounts", {id: "biz_seller"})
    api(:get, "accounts/biz_seller", {id: "biz_seller", parent_account: {id: "biz_test"}})
    record.create_account(email: "seller@example.test", title: "Test seller")
    assert Pay::Whop::Merchant.registered?("biz_seller")
    assert_equal "biz_seller", record.reload.processor_id
  end

  test "unrelated accounts cannot be enrolled" do
    record = @user.set_merchant_processor(:whop)
    api(:post, "accounts", {id: "biz_foreign"})
    api(:get, "accounts/biz_foreign", {id: "biz_foreign", parent_account: {id: "biz_other"}})
    assert_raises(Pay::Whop::IdentityError) { record.create_account(email: "seller@example.test", title: "Test seller") }
    assert_nil record.reload.processor_id
    assert_not Pay::Whop::Merchant.registered?("biz_foreign")
  end

  test "signed subaccount webhook updates only its scoped customer" do
    seller = merchant.customer_for(@user)
    api(:get, "payments/pay_test", seller_payment(seller))
    body, headers = sign_event(account: "biz_seller")
    post "/pay/whop/webhooks", params: body, headers: headers
    assert_response :ok
    delivery = Pay::Whop::Delivery.sole
    assert_equal "biz_seller", delivery.account_id
    delivery.process!
    assert_equal seller.id, Pay::Whop::Charge.sole.customer_id
    assert_empty @customer.charges
  end

  test "subaccount metadata cannot claim a platform customer" do
    merchant
    api(:get, "payments/pay_test", seller_payment(@customer))
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Charge.sync("pay_test", account_id: "biz_seller") }
    assert_nil @customer.reload.processor_id
  end

  test "webhook envelope and API resource account must match" do
    seller = merchant.customer_for(@user)
    api(:get, "payments/pay_test", seller_payment(seller))
    body, headers = sign_event(account: "biz_test")
    post "/pay/whop/webhooks", params: body, headers: headers
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Delivery.sole.process! }
    assert_empty Pay::Whop::Charge.all
  end

  test "merchant registration is scoped to the configured environment" do
    merchant
    Pay::Whop.environment = "production"
    assert_not Pay::Whop::Merchant.registered?("biz_seller")
    assert_raises(Pay::Whop::IdentityError) { merchant.customer_for(@user) }
  end

  test "payout portal uses a verified subaccount" do
    merchant
    api(:get, "accounts/biz_seller", {id: "biz_seller", parent_account: {id: "biz_test"}})
    request = api(:post, "account_links", {url: "https://sandbox.whop.com/payouts/test"},
      body: {account_id: "biz_seller", use_case: "payouts_portal", return_url: "https://example.test", refresh_url: "https://example.test/refresh"})
    merchant.account_link(use_case: "payouts_portal", return_url: "https://example.test", refresh_url: "https://example.test/refresh")
    assert_requested request
  end

  test "transfer records processing separately from settlement and retains idempotency" do
    merchant
    api(:get, "accounts/biz_seller", {id: "biz_seller", parent_account: {id: "biz_test"}})
    object = {id: "ctt_test", object: "transfer", origin: {id: "biz_test"}, destination: {id: "biz_seller"}, status: "processing", amount: nil}
    request = api(:post, "transfers", object).with { |req|
      body = JSON.parse(req.body)
      body["origin_id"] == "biz_test" && body["destination_id"] == "biz_seller" && body["idempotence_key"] == "transfer-order-1" && body["amount"].to_s == "9.0"
    }
    api(:get, "transfers/ctt_test", object)
    transfer = merchant.transfer(amount: 900, idempotency_key: "transfer-order-1")
    assert_equal "processing", transfer.status
    assert_nil transfer.amount
    assert_requested request
    api(:get, "transfers/ctt_test", object.merge(status: "succeeded", amount: money("9.00")))
    transfer.sync!
    assert_equal "succeeded", transfer.status
    assert_equal 900, transfer.amount
    api(:get, "transfers/ctt_test", object)
    transfer.sync!
    assert_equal "succeeded", transfer.status
    assert_equal 900, transfer.amount
  end
  test "transfers preserve fractional major units in the request" do
    merchant
    api(:get, "accounts/biz_seller", {id: "biz_seller", parent_account: {id: "biz_test"}})
    object = {id: "ctt_decimal", object: "transfer", origin: {id: "biz_test"}, destination: {id: "biz_seller"}, status: "succeeded", amount: money("9.43")}
    request = api(:post, "transfers", object).with { |req| JSON.parse(req.body, decimal_class: BigDecimal)["amount"] == BigDecimal("9.43") }
    api(:get, "transfers/ctt_decimal", object)
    assert_equal 943, merchant.transfer(amount: 943, idempotency_key: "decimal-transfer").amount
    assert_requested request
  end
end
