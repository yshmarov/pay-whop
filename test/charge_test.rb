require "test_helper"

class ChargeTest < ActiveSupport::TestCase
  test "money converts exactly to minor units including zero-decimal currencies" do
    assert_equal 1043, Pay::Whop.minor_units(money("10.43"))
    assert_equal 1200, Pay::Whop.minor_units(money("1200", "jpy", 0))
    assert_equal 1234, Pay::Whop.minor_units(money("1.234", "kwd", 3))
    assert_raises(Pay::Whop::InvalidPayload) { Pay::Whop.minor_units(money("1.001")) }
  end

  test "pending and failed payments do not create successful charges" do
    %w[pending open uncollectible].each do |status|
      api(:get, "payments/pay_test", payment(status: status))
      assert_nil Pay::Whop::Charge.sync("pay_test")
    end
    assert_empty @customer.charges
  end

  test "payment-first delivery creates and links its subscription" do
    api(:get, "payments/pay_test", payment(membership_id: "mem_test"))
    api(:get, "memberships/mem_test", membership)
    charge = Pay::Whop::Charge.sync("pay_test")
    assert_equal 1043, charge.amount
    assert_equal "mem_test", charge.subscription.processor_id
    Pay::Whop::Charge.sync("pay_test")
    assert_equal 1, @customer.charges.count
    assert_equal 1, @customer.subscriptions.count
  end

  test "refund sends an idempotency key and re-reads the confirmed amount" do
    api(:get, "payments/pay_test", payment)
    charge = Pay::Whop::Charge.sync("pay_test")
    request = api(:post, "payments/pay_test/refund", payment(refunded_amount: money("10.43")))
      .with(headers: {"Idempotency-Key" => "refund-attempt-1"})
    stub_request(:get, "https://sandbox-api.whop.com/api/v1/payments/pay_test").to_return(
      {status: 200, body: payment.to_json, headers: {"Content-Type" => "application/json"}},
      {status: 200, body: payment(refunded_amount: money("10.43"), updated_at: "2026-11-08T00:00:00Z").to_json, headers: {"Content-Type" => "application/json"}}
    )
    charge.refund!(idempotency_key: "refund-attempt-1")
    assert charge.full_refund?
    assert_requested request
  end

  test "refund currency mismatch is rejected" do
    api(:get, "payments/pay_test", payment(refunded_amount: money("1", "eur")))
    assert_raises(Pay::Whop::InvalidPayload) { Pay::Whop::Charge.sync("pay_test") }
    assert_empty @customer.charges
  end

  test "insufficient seller balance leaves the charge unrefunded" do
    api(:get, "payments/pay_test", payment)
    charge = Pay::Whop::Charge.sync("pay_test")
    request = api(:post, "payments/pay_test/refund",
      {error: {type: "bad_request", message: "Insufficient funds", code: "not_enough_balance"}}, status: 400)

    assert_raises(Pay::Whop::ApiError) { charge.refund! }
    assert_equal 0, charge.reload.amount_refunded
    assert_requested request, times: 1
  end
end
