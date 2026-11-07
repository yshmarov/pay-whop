require "test_helper"

class ResourcesTest < ActiveSupport::TestCase
  def invoice(**changes)
    {id: "pay_invoice", account_id: "biz_test", member_id: "mber_test", metadata: @customer.checkout_metadata,
     status: "draft", total: money("20.00"), updated_at: "2026-11-07T00:00:00Z", checkout_link: "https://sandbox.whop.com/invoice/test"}.merge(changes)
  end

  test "creating a draft invoice does not pretend a payment occurred" do
    @customer.update!(processor_id: "mber_test")
    api(:post, "invoices", invoice)
    api(:get, "invoices/pay_invoice", invoice)
    record = @customer.create_invoice(items: [{variant_id: "plan_test", quantity: 1}])
    assert_equal @customer.id, record.customer_id
    assert_equal "draft", record.status
    assert_equal 2000, record.amount
    assert_empty @customer.charges
  end

  test "paid invoice synchronizes a real charge and stale snapshots do not reverse it" do
    api(:get, "invoices/pay_invoice", invoice(status: "paid", updated_at: "2026-11-08T00:00:00Z"))
    api(:get, "payments/pay_invoice", payment(id: "pay_invoice", total: money("20.00")))
    record = Pay::Whop::Invoice.sync("pay_invoice", account_id: "biz_test")
    assert_equal 2000, @customer.charges.sole.amount
    api(:get, "invoices/pay_invoice", invoice)
    record.sync!
    assert_equal "paid", record.status
  end

  test "invoice issue failure leaves draft state" do
    api(:get, "invoices/pay_invoice", invoice)
    record = Pay::Whop::Invoice.sync("pay_invoice", account_id: "biz_test")
    api(:post, "invoices/pay_invoice/issue", {error: "unavailable"}, status: 503)
    assert_raises(Whop_sdk::Errors::ApiError) { record.issue }
    assert_equal "draft", record.reload.status
  end

  test "invoice from another account cannot update local records" do
    api(:get, "invoices/pay_invoice", invoice(account_id: "biz_other"))
    assert_raises(Pay::Whop::IdentityError) { Pay::Whop::Invoice.sync("pay_invoice", account_id: "biz_test") }
    assert_empty Pay::Whop::Invoice.all
  end

  test "disputes are scoped via their original charge and do not persist buyer or evidence data" do
    api(:get, "payments/pay_test", payment)
    object = {id: "dspt_test", account_id: "biz_test", payment: {id: "pay_test"}, status: "needs_response", currency: "usd", updated_at: "2026-11-07T00:00:00Z", reason: "fraudulent", evidence: {customer_name: "Do not retain"}}
    api(:get, "disputes/dspt_test", object)
    dispute = Pay::Whop::Dispute.sync("dspt_test", account_id: "biz_test")
    assert_equal @customer.id, dispute.customer_id
    assert_not dispute.data.key?("evidence")
    request = api(:patch, "disputes/dspt_test", object)
    dispute.update_evidence(evidence: {product_description: "A digital download"})
    assert_requested request
  end
end
