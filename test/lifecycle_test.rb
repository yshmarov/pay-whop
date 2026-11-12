require "test_helper"

class LifecycleTest < ActiveSupport::TestCase
  def subscription
    api(:get, "memberships/mem_test", membership)
    Pay::Whop::Subscription.sync("mem_test")
  end

  test "retry uses the existing membership payment and an explicit idempotency key" do
    record = subscription
    failed = payment(status: "failed", membership_id: "mem_test")
    api(:get, "payments?account_id=biz_test&member_id=mber_test&membership_id=mem_test&order=created_at&direction=desc&first=1&after",
      {data: [failed], page_info: {has_next_page: false}})
    stub = api(:get, "payments/pay_test", failed)
    stub.then.to_return(body: failed.to_json, headers: {"Content-Type" => "application/json"}).then
      .to_return(body: payment(membership_id: "mem_test").to_json, headers: {"Content-Type" => "application/json"})
    request = api(:post, "payments/pay_test/retry", {status: "succeeded"}).with(headers: {"Idempotency-Key" => "recover-1"})
    charge = record.retry_failed_payment(idempotency_key: "recover-1")
    assert_equal "pay_test", charge.processor_id
    assert_equal record.id, charge.subscription_id
    assert_requested request, times: 1
    assert_not_requested :post, "https://sandbox-api.whop.com/api/v1/payments"
  end

  test "retry cannot charge a payment from another membership" do
    record = subscription
    api(:get, "payments/pay_test", payment(status: "failed", membership_id: "mem_other"))
    assert_raises(Pay::Whop::IdentityError) { record.retry_failed_payment(payment_id: "pay_test") }
    assert_not_requested :post, %r{/retry}
  end

  test "an already paid retry synchronizes without requesting another charge" do
    record = subscription
    api(:get, "payments/pay_test", payment(membership_id: "mem_test"))
    assert_equal "pay_test", record.retry_failed_payment(payment_id: "pay_test").processor_id
    assert_not_requested :post, %r{/retry}
  end

  test "renewal reductions preserve precision and reject increases" do
    record = subscription
    request = api(:patch, "memberships/mem_test", membership(renewal_price: money("8.55")), body: {renewal_price: 8.55})
      .with(headers: {"Idempotency-Key" => "reduce-1"})
    record.reduce_renewal_price(855, idempotency_key: "reduce-1")
    assert_requested request, times: 1
    assert_raises(ArgumentError) { record.reduce_renewal_price(1001) }
    assert_raises(ArgumentError) { record.reduce_renewal_price(855, decimals: 3) }
  end

  test "billing period and renewal date updates are separate and refresh confirmed state" do
    record = subscription
    period = api(:patch, "memberships/mem_test", membership, body: {billing_period_days: 90})
    date = Time.current.utc.beginning_of_day + 60.days
    renewal = api(:patch, "memberships/mem_test", membership, body: {current_period_end: date.iso8601})
    record.change_billing_period(90)
    record.change_next_renewal(date)
    assert_requested period
    assert_requested renewal
    assert_raises(ArgumentError) { record.change_billing_period(366) }
    assert_raises(ArgumentError) { record.change_next_renewal(Time.current) }
  end

  test "provider rejection leaves the saved subscription unchanged" do
    record = subscription
    api(:patch, "memberships/mem_test", {error: {type: "invalid_request", message: "Paused memberships cannot be changed"}}, status: 400)
    error = assert_raises(Pay::Error) { record.reduce_renewal_price(500) }
    assert_equal 400, error.status
    assert_equal "active", record.reload.status
  end

  test "SCA recovery exposes only the configured Whop host and never grants access" do
    @customer.update!(processor_id: "mber_test")
    ["https://sandbox.whop.com/payments/recover/test", "https://evil.test/recover", "http://sandbox.whop.com/recover", "https://whop.com/recover"].each do |url|
      api(:get, "payments/pay_test", payment(status: "requires_action", recovery_url: url))
      error = assert_raises(Pay::Whop::PaymentIncomplete) { @customer.confirmed_charge(@customer.payment("pay_test")) }
      if url.start_with?("https://sandbox.whop.com/")
        assert_equal url, error.recovery_url
      else
        assert_nil error.recovery_url
      end
    end
    assert_empty @customer.charges
    assert_not @customer.subscribed?
  end

  test "trial ending notification reconciles actual state before application callbacks" do
    api(:get, "memberships/mem_test", membership(status: "trialing"))
    delivery = Pay::Whop::Delivery.create!(event_id: "evt_trial", event_type: "membership.trial_ending_soon", resource_id: "mem_test", account_id: "biz_test", environment: "sandbox")
    observed = []
    listener = Pay::Webhooks.delegator.subscribe("whop.membership.trial_ending_soon") { |event| observed << [event.fetch(:delivery).id, @customer.subscriptions.sole.on_trial?] }
    delivery.process!
    delivery.process!
    assert_equal [[delivery.id, true]], observed
  ensure
    ActiveSupport::Notifications.unsubscribe(listener) if listener
  end
end
