require "test_helper"

class MarketplaceOperationsTest < ActiveSupport::TestCase
  def merchant
    @merchant ||= @user.set_merchant_processor(:whop, processor_id: "biz_seller", data: {whop_platform_id: "biz_test", whop_environment: "sandbox"})
  end

  def account(**options)
    api(:get, "accounts/biz_seller", {id: "biz_seller", parent_account: {id: "biz_test"}, status: "active", capabilities: {transfer: "pending"}, required_actions: [{action: "verify_identity", status: "pending", blocked_capabilities: ["transfer"], cta: {url: "https://sandbox.whop.com/test"}, internal_data: "omit"}]}.merge(options))
  end

  def payout(**options)
    {id: "wdrl_test", status: "processing", amount: "9.00", net_amount: "8.00", fee_amount: "1.00", currency: "usd", payout_request_id: "pay_request", payout_method: {account_number: "omit"}}.merge(options)
  end

  test "readiness is fresh and unknown capabilities remain unavailable" do
    account
    assert_equal "active", merchant.readiness["status"]
    assert_not merchant.capability_active?(:transfer)
    assert_not merchant.capability_active?(:unknown)
    assert_not merchant.readiness["required_actions"].first.key?("internal_data")
    account(capabilities: {transfer: "active"})
    assert merchant.capability_active?(:transfer)
    assert merchant.onboarding_complete?(capabilities: %w[transfer])
    assert_not merchant.onboarding_complete?
    account(status: "suspended", capabilities: {transfer: "active"})
    assert_not merchant.onboarding_complete?(capabilities: %w[transfer])
  end

  test "Pay style merchant login link selects the hosted payout portal" do
    account
    request = api(:post, "account_links", {url: "https://sandbox.whop.com/test"})
      .with { |req| JSON.parse(req.body)["use_case"] == "payouts_portal" }
    merchant.login_link(refresh_url: "https://example.test/refresh", return_url: "https://example.test")
    assert_requested request
  end

  test "balances retain currency precision and reject another ledger owner" do
    api(:get, "ledger_accounts/biz_seller", {owner: {id: "biz_seller"}, balances: [{currency: "usd", balance: 1.23, pending_balance: 0.04, reserve_balance: 0, payout_account_details: "omit"}]})
    balance = merchant.balance.sole
    assert_equal BigDecimal("1.23"), balance["balance"]
    assert_equal BigDecimal("0.04"), balance["pending_balance"]
    assert_not balance.key?("payout_account_details")
    api(:get, "ledger_accounts/biz_seller", {owner: {id: "biz_other"}, balances: []})
    assert_raises(Pay::Whop::IdentityError) { merchant.balance }
  end

  test "payout status is proven through the merchant scoped list across pages" do
    merchant
    api(:get, "payouts?account_id=biz_seller&first=100", {data: [], page_info: {has_next_page: true, end_cursor: "next"}})
    api(:get, "payouts?account_id=biz_seller&first=100&after=next", {data: [payout], page_info: {has_next_page: false}})
    record = Pay::Whop::Payout.sync("pay_request", account_id: "biz_seller")
    assert_equal merchant.id, record.merchant_id
    assert_equal "processing", record.status
    assert_equal "9.00", record.data["amount"]
    assert_not record.data.key?("payout_method")
    assert_not_requested :get, "https://sandbox-api.whop.com/api/v1/payouts/pay_request"
  end

  test "unowned payouts and mismatched list accounts create no records" do
    merchant
    api(:get, "payouts?account_id=biz_seller&first=100", {data: [], page_info: {has_next_page: false}})
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Payout.sync("wdrl_foreign", account_id: "biz_seller") }
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Payout.sync_object(payout(account_id: "biz_other").stringify_keys, merchant: merchant) }
    assert_empty merchant.payouts
  end

  test "payout completion cannot regress to pending but can reverse" do
    record = Pay::Whop::Payout.sync_object(payout(status: "completed").stringify_keys, merchant: merchant)
    Pay::Whop::Payout.sync_object(payout.stringify_keys, merchant: merchant)
    assert_equal "completed", record.reload.status
    Pay::Whop::Payout.sync_object(payout(status: "reversed").stringify_keys, merchant: merchant)
    assert_equal "reversed", record.reload.status
    Pay::Whop::Payout.sync_object(payout(status: "completed").stringify_keys, merchant: merchant)
    assert_equal "reversed", record.reload.status
  end

  test "platform payout webhooks synchronize without creating a fictitious seller" do
    api(:get, "payouts?account_id=biz_test&first=100", {data: [payout(status: "completed")], page_info: {has_next_page: false}})
    delivery = Pay::Whop::Delivery.create!(event_id: "evt_payout", event_type: "payout.updated", resource_id: "wdrl_test", account_id: "biz_test", environment: "sandbox")
    delivery.process!
    record = Pay::Whop::Payout.sole
    assert_equal "biz_test", record.account_id
    assert_nil record.merchant_id
    assert_nil record.customer_id
    assert_equal "completed", record.status
    api(:get, "payouts?account_id=biz_test&first=100", {data: [payout], page_info: {has_next_page: false}})
    record.sync!
    assert_equal "completed", record.reload.status
    api(:get, "payouts?account_id=biz_test&first=100", {data: [payout(status: "reversed")], page_info: {has_next_page: false}})
    record.sync!
    assert_equal "reversed", record.reload.status
    api(:get, "payouts?account_id=biz_test&first=100", {data: [payout(status: "completed")], page_info: {has_next_page: false}})
    record.sync!
    assert_equal "reversed", record.reload.status
    assert_empty Pay::Whop::Merchant.all
  end

  test "marketplace reconciliation verifies both ends of each transfer" do
    account
    object = {id: "ctt_test", origin: {id: "biz_test"}, destination: {id: "biz_seller"}, status: "succeeded", amount: money("9.00")}
    api(:get, "transfers?origin_id=biz_test&destination_id=biz_seller&first=100", {data: [object], page_info: {has_next_page: false}})
    api(:get, "transfers/ctt_test", object)
    api(:get, "payouts?account_id=biz_seller&first=100", {data: [payout], page_info: {has_next_page: false}})
    assert_equal({transfers: 1, payouts: 1}, merchant.reconcile!)
    assert_equal 900, merchant.transfers.sole.amount
    api(:get, "transfers?origin_id=biz_test&destination_id=biz_seller&first=100", {data: [object.merge(destination: {id: "biz_other"})], page_info: {has_next_page: false}})
    assert_raises(Pay::Whop::IdentityError) { merchant.reconcile! }
  end

  test "repeated pagination cursor stops reconciliation" do
    api(:get, "payouts?account_id=biz_seller&first=100", {data: [], page_info: {has_next_page: true, end_cursor: "loop"}})
    api(:get, "payouts?account_id=biz_seller&first=100&after=loop", {data: [], page_info: {has_next_page: true, end_cursor: "loop"}})
    merchant
    assert_raises(Pay::Whop::InvalidPayload) { Pay::Whop::Payout.sync("wdrl_test", account_id: "biz_seller") }
  end
end
