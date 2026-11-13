require "test_helper"

class SubscriptionTest < ActiveSupport::TestCase
  test "trial expiry cannot grant indefinite access while a renewal webhook is missing" do
    finish = 21.days.from_now.change(usec: 0)
    api(:get, "memberships/mem_test", membership(status: "trialing", initial_price: money("0.00"), current_period_end: finish.iso8601))
    subscription = Pay::Whop::Subscription.sync("mem_test")
    assert subscription.active?
    assert subscription.on_trial?
    travel_to(finish) do
      assert_not subscription.active?
      assert_not @customer.subscribed?
    end
  end

  test "verified trial membership does not require a fabricated positive charge" do
    api(:get, "memberships/mem_test", membership(status: "trialing", initial_price: money("0.00"), current_period_end: 21.days.from_now.iso8601))
    result = @customer.membership("mem_test")
    subscription = @customer.sync_membership(result.id)
    assert subscription.on_trial?
    assert_empty @customer.charges
  end

  test "reading another customer's membership does not bind their previously unbound member" do
    other = User.create!(email: "other@example.test").set_payment_processor(:whop, data: {whop_account_id: "biz_test", whop_environment: "sandbox"})
    api(:get, "memberships/mem_test", membership(metadata: other.checkout_metadata))
    assert_raises(Pay::Whop::IdentityError) { @customer.membership("mem_test") }
    assert_raises(Pay::Whop::IdentityError) { @customer.sync_membership("mem_test") }
    assert_nil other.reload.processor_id
    assert_nil @customer.reload.processor_id
  end

  test "membership maps to a Pay subscription and repeat synchronization is idempotent" do
    api(:get, "memberships/mem_test", membership)
    2.times { Pay::Whop::Subscription.sync("mem_test") }
    subscription = @customer.subscriptions.sole
    assert subscription.active?
    assert @user.payment_processor.subscribed?
    assert_equal "plan_test", subscription.processor_plan
  end

  test "older API snapshots cannot undo a newer cancellation" do
    api(:get, "memberships/mem_test", membership(status: "canceled", canceled_at: "2026-11-07T00:00:00Z"))
    subscription = Pay::Whop::Subscription.sync("mem_test")
    api(:get, "memberships/mem_test", membership(updated_at: "2026-11-06T00:00:00Z"))
    subscription.sync!
    assert_equal "canceled", subscription.status
    assert_not subscription.active?
  end

  test "cancel uses period-end semantics and only stores API-confirmed state" do
    api(:get, "memberships/mem_test", membership)
    subscription = Pay::Whop::Subscription.sync("mem_test")
    request = api(:post, "memberships/mem_test/cancel", membership(cancel_at_period_end: true), body: {cancel_at_period_end: true})
    api(:get, "memberships/mem_test", membership(cancel_at_period_end: true, updated_at: "2026-11-08T00:00:00Z"))
    subscription.cancel
    assert subscription.on_grace_period?
    assert subscription.active?
    assert_requested request
  end

  test "failed cancellation does not report local success" do
    api(:get, "memberships/mem_test", membership)
    subscription = Pay::Whop::Subscription.sync("mem_test")
    api(:post, "memberships/mem_test/cancel", {error: "unavailable"}, status: 503)
    assert_raises(Pay::Whop::ApiError) { subscription.cancel }
    assert_nil subscription.reload.ends_at
  end

  test "one-time memberships do not become active subscriptions" do
    api(:get, "memberships/mem_test", membership(status: "completed", renewal_price: nil))
    assert_nil Pay::Whop::Subscription.sync("mem_test")
    assert_empty @customer.subscriptions
  end

  test "membership from another account cannot link a customer" do
    api(:get, "memberships/mem_test", membership(account: {id: "biz_other"}))
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Subscription.sync("mem_test") }
    assert_nil @customer.reload.processor_id
  end
  test "immediate cancellation ends access and cannot be resumed" do
    api(:get, "memberships/mem_test", membership)
    subscription = Pay::Whop::Subscription.sync("mem_test")
    api(:post, "memberships/mem_test/cancel", membership(status: "canceled"), body: {cancel_at_period_end: false})
    api(:get, "memberships/mem_test", membership(status: "canceled", cancel_at_period_end: true, canceled_at: "2026-11-07T00:00:00Z", updated_at: "2026-11-08T00:00:00Z"))
    subscription.cancel_now!
    assert_not subscription.active?
    assert_not subscription.resumable?
    assert_raises(Pay::Whop::Error) { subscription.resume }
  end

  test "resume clears a scheduled cancellation after the API confirms it" do
    api(:get, "memberships/mem_test", membership(cancel_at_period_end: true))
    subscription = Pay::Whop::Subscription.sync("mem_test")
    api(:patch, "memberships/mem_test", membership, body: {cancel_at_period_end: false})
    api(:get, "memberships/mem_test", membership(updated_at: "2026-11-08T00:00:00Z"))
    subscription.resume
    assert subscription.active?
    assert_nil subscription.ends_at
  end
end
