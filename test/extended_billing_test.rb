require "test_helper"

class ExtendedBillingTest < ActiveSupport::TestCase
  def saved_methods
    @customer.update!(processor_id: "mber_test")
    api(:get, "payment_methods?after&first=100&member_id=mber_test", {
      data: [{id: "payt_test", typename: "CardPaymentMethod", payment_method_type: "card", card: {brand: "visa", last4: "4242", exp_month: 12, exp_year: 2034}}],
      page_info: {has_next_page: false}
    })
  end

  test "one-time checkout creates an inline variant with exact price and platform fee" do
    request = api(:post, "checkout_configurations", {id: "ch_test", purchase_url: "https://sandbox.whop.com/test"})
      .with { |req| JSON.parse(req.body)["variant"] == {"currency" => "usd", "billing_type" => "one_time", "initial_price" => 10.43, "application_fee_amount" => 1.25} }
    @customer.checkout_charge(amount: 1043, application_fee_amount: 125, redirect_url: "https://example.test")
    assert_requested request
    assert_raises(ArgumentError) { @customer.checkout_charge(amount: 1043, application_fee_amount: 1043, redirect_url: "https://example.test") }
  end

  test "setup checkout carries signed identity and never requests a charge" do
    request = api(:post, "checkout_configurations", {id: "ch_setup", purchase_url: "https://sandbox.whop.com/test"})
      .with { |req| JSON.parse(req.body)["mode"] == "setup" && JSON.parse(req.body).dig("metadata", "pay_customer").present? }
    @customer.setup_checkout(redirect_url: "https://example.test")
    assert_requested request
  end

  test "saved methods are resolved through this member and default selection is local" do
    saved_methods
    method = @customer.add_payment_method("payt_test", default: true)
    assert_equal "4242", method.last4
    assert method.default?
    assert_raises(ActiveRecord::RecordNotFound) { @customer.add_payment_method("payt_foreign") }
  end

  test "setup success resolves the signed customer and synchronizes the saved method" do
    saved_methods
    api(:get, "setup_intents/sint_test", {id: "sint_test", account_id: "biz_test", member_id: "mber_test", status: "succeeded", payment_method_id: "payt_test", metadata: @customer.checkout_metadata})
    method = Pay::Whop::PaymentMethod.sync_setup("sint_test", account_id: "biz_test")
    assert_equal @customer.id, method.customer_id
  end

  test "off-session charge uses the linked member and synchronizes only paid payments" do
    saved_methods
    @customer.add_payment_method("payt_test", default: true)
    request = api(:post, "payments", payment).with { |req|
      body = JSON.parse(req.body)
      body["member_id"] == "mber_test" && body["account_id"] == "biz_test" && body["payment_method_id"] == "payt_test" && body["off_session"] && body.dig("variant", "initial_price").to_s == "10.43"
    }
    api(:get, "payments/pay_test", payment)
    charge = @customer.charge(1043)
    assert_equal 1043, charge.amount
    assert_requested request
  end

  test "pending direct payment exposes its state and creates no charge" do
    saved_methods
    @customer.add_payment_method("payt_test", default: true)
    api(:post, "payments", payment(status: "pending"))
    error = assert_raises(Pay::Whop::PaymentIncomplete) { @customer.charge(1043) }
    assert_equal "pay_test", error.payment.id
    assert_empty @customer.charges
  end

  test "another member payment cannot be captured or voided" do
    @customer.update!(processor_id: "mber_test")
    api(:get, "payments/pay_other", payment(id: "pay_other", member_id: "mber_other", metadata: {}))
    assert_raises(Pay::Whop::IdentityError) { @customer.capture("pay_other") }
    assert_raises(Pay::Whop::IdentityError) { @customer.void("pay_other") }
    assert_not_requested :post, %r{payments/pay_other/}
  end

  test "partial refund preserves fractional currency units at the SDK boundary" do
    api(:get, "payments/pay_test", payment)
    charge = Pay::Whop::Charge.sync("pay_test")
    request = api(:post, "payments/pay_test/refund", payment, body: {partial_amount: 2.55})
    charge.refund!(255)
    assert_requested request
    assert_equal 0, charge.amount_refunded
    assert_raises(ArgumentError) { charge.refund!(1044) }
    assert_raises(ArgumentError) { charge.refund!(0) }
  end

  test "paused billing retains access until the paid period ends" do
    api(:get, "memberships/mem_test", membership(most_recent_action: "paused_at", most_recent_action_at: "2026-11-07T00:00:00Z"))
    subscription = Pay::Whop::Subscription.sync("mem_test")
    assert subscription.paused?
    assert subscription.active?
    assert_includes @customer.subscriptions.active, subscription
    travel_to subscription.current_period_end + 1.second do
      assert_not subscription.active?
      assert_not_includes @customer.subscriptions.active, subscription
    end
  end

  test "pause resume and free days use their dedicated membership endpoints" do
    api(:get, "memberships/mem_test", membership)
    subscription = Pay::Whop::Subscription.sync("mem_test")
    pause = api(:post, "memberships/mem_test/pause", membership)
    resume = api(:post, "memberships/mem_test/resume", membership)
    extend_request = api(:post, "memberships/mem_test/extend", membership, body: {days: 5})
    subscription.pause
    subscription.unpause
    subscription.add_free_days(5)
    [pause, resume, extend_request].each { |request| assert_requested request }
    assert_raises(ArgumentError) { subscription.add_free_days(0) }
  end

  test "trial and past-due snapshots retain their actual state" do
    api(:get, "memberships/mem_test", membership(status: "trialing"))
    subscription = Pay::Whop::Subscription.sync("mem_test")
    assert subscription.on_trial?
    api(:get, "memberships/mem_test", membership(status: "past_due", updated_at: "2026-11-08T00:00:00Z"))
    subscription.sync!
    assert_equal "past_due", subscription.status
    assert_nil subscription.trial_ends_at
  end

  test "a paid one-time membership produces a charge without a recurring subscription" do
    api(:get, "payments/pay_test", payment(membership_id: "mem_test"))
    api(:get, "memberships/mem_test", membership(status: "completed", renewal_price: nil))
    charge = Pay::Whop::Charge.sync("pay_test")
    assert_equal 1043, charge.amount
    assert_nil charge.subscription
  end
  test "capture reconciles the payment after a status-only API response" do
    @customer.update!(processor_id: "mber_test")
    api(:get, "payments/pay_test", payment)
    request = api(:post, "payments/pay_test/capture", {status: "succeeded"})
    charge = @customer.capture("pay_test")
    assert_equal 1043, charge.amount
    assert_requested request
  end

  test "a failed fractional refund never becomes a full refund" do
    api(:get, "payments/pay_test", payment)
    charge = Pay::Whop::Charge.sync("pay_test")
    request = api(:post, "payments/pay_test/refund", {error: "unavailable"}, body: {partial_amount: 0.01}, status: 503)
    assert_raises(Pay::Whop::ApiError) { charge.refund!(1, idempotency_key: "partial-retry") }
    assert_requested request, times: 1
    assert_equal 0, charge.reload.amount_refunded
  end

  test "zero and three-decimal money is encoded without cent assumptions" do
    assert_equal 125, Pay::Whop.major_units(125, decimals: 0)
    assert_in_delta 1.255, Pay::Whop.major_units(1255, decimals: 3)
    assert_raises(ArgumentError) { Pay::Whop.major_units(12.5) }
    assert_raises(ArgumentError) { Pay::Whop.major_units(10**22 + 1) }
  end
  test "embedded setup and payment intents preserve signed ownership" do
    setup = api(:post, "setup_intents", {id: "sint_test", status: "requires_action"}).with { |request|
      body = JSON.parse(request.body)
      body["confirmation_token"] == "ctok_test" && body["account_id"] == "biz_test" && body.dig("metadata", "pay_customer").present?
    }
    payment_request = api(:post, "payments", payment(status: "open"))
    result = @customer.create_setup_intent(confirmation_token: "ctok_test", return_url: "https://example.test")
    assert_equal "requires_action", result.status
    result = @customer.create_payment_intent(confirmation_token: "ctok_test", return_url: "https://example.test", variant_id: "plan_test")
    assert_equal "open", result.status
    assert_empty @customer.charges
    assert_requested setup
    assert_requested payment_request
  end

  test "recurring reactivation is rejected and promo codes use the proper endpoint" do
    api(:get, "memberships/mem_test", membership)
    subscription = Pay::Whop::Subscription.sync("mem_test")
    promo = api(:post, "memberships/mem_test/apply_promo_code", membership, body: {promo_code: "SAVE20"})
    assert_raises(Pay::NotSupportedError) { subscription.reactivate(days: 30) }
    subscription.apply_promo_code(promo_code: "SAVE20")
    assert_requested promo
  end
  test "one-time entitlements track access independently of recurring subscriptions" do
    api(:get, "memberships/mem_test", membership(status: "completed", renewal_price: nil, expires_at: "2027-01-01T00:00:00Z"))
    Pay::Whop::Subscription.sync("mem_test")
    entitlement = @customer.entitlements.sole
    assert entitlement.active?
    assert_not @customer.subscribed?
    travel_to Time.utc(2027, 1, 2) do
      assert_not entitlement.active?
    end
    request = api(:post, "memberships/mem_test/reactivate", membership(status: "completed", renewal_price: nil), body: {days: 30})
    entitlement.reactivate(days: 30)
    assert_requested request
  end
end
