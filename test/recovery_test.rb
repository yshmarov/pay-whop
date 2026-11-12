require "test_helper"

class RecoveryTest < ActiveSupport::TestCase
  test "customer reconciliation uses account and member filters and refreshes confirmed records" do
    @customer.update!(processor_id: "mber_test")
    {memberships: [membership], payments: [payment], invoices: []}.each do |endpoint, objects|
      api(:get, "#{endpoint}?account_id=biz_test&member_id=mber_test&first=100&after", {data: objects, page_info: {has_next_page: false}})
    end
    api(:get, "memberships/mem_test", membership)
    api(:get, "payments/pay_test", payment)
    assert_equal({memberships: 1, payments: 1, invoices: 0, skipped: 0}, @customer.reconcile!)
    assert_equal 1043, @customer.charges.sole.amount
    assert_equal "active", @customer.subscriptions.sole.status
  end

  test "unverifiable references from another application are reported and never imported" do
    @customer.update!(processor_id: "mber_test")
    api(:get, "memberships?account_id=biz_test&member_id=mber_test&first=100&after", {data: [membership(metadata: {pay_customer: "another-application-reference"})], page_info: {has_next_page: false}})
    %w[payments invoices].each do |endpoint|
      api(:get, "#{endpoint}?account_id=biz_test&member_id=mber_test&first=100&after", {data: [], page_info: {has_next_page: false}})
    end
    assert_equal 1, @customer.reconcile![:skipped]
    assert_empty @customer.subscriptions
    assert_not_requested :get, "https://sandbox-api.whop.com/api/v1/memberships/mem_test"
  end

  test "a different member in reconciliation cannot create local billing records" do
    @customer.update!(processor_id: "mber_test")
    api(:get, "memberships?account_id=biz_test&member_id=mber_test&first=100&after", {data: [membership(member_id: "mber_other", metadata: {})], page_info: {has_next_page: false}})
    assert_raises(Pay::Whop::IdentityError) { @customer.reconcile! }
    assert_empty @customer.subscriptions
  end

  test "recovery includes old unprocessed deliveries and omits recent and processed ones" do
    old = Pay::Whop::Delivery.create!(event_id: "evt_old", event_type: "payment.succeeded", resource_id: "pay_test", account_id: "biz_test", environment: "sandbox", created_at: 3.days.ago)
    old.dup.tap { |delivery|
      delivery.event_id = "evt_recent"
      delivery.created_at = Time.current
    }.save!
    old.dup.tap { |delivery|
      delivery.event_id = "evt_done"
      delivery.processed_at = Time.current
    }.save!
    assert_enqueued_with(job: Pay::Whop::ProcessDeliveryJob, args: [old]) do
      Pay::Whop::RecoverDeliveriesJob.perform_now
    end
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == Pay::Whop::ProcessDeliveryJob }
  end

  test "permission errors stay pending and emit an actionable failure without automatic retry" do
    delivery = Pay::Whop::Delivery.create!(event_id: "evt_denied", event_type: "payment.succeeded", resource_id: "pay_test", account_id: "biz_test", environment: "sandbox")
    api(:get, "payments/pay_test", {error: {type: "forbidden", message: "Permission required"}}, status: 403)
    observed = []
    subscriber = ActiveSupport::Notifications.subscribe("delivery_failed.pay_whop") { |*args| observed << args.last }
    assert_no_enqueued_jobs { Pay::Whop::ProcessDeliveryJob.perform_now(delivery) }
    assert_equal [403], observed.map { |event| event[:status] }
    assert_nil delivery.reload.processed_at
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
