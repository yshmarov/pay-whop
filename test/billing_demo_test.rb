require "test_helper"

class BillingDemoTest < ActionDispatch::IntegrationTest
  setup do
    ENV["WHOP_VARIANT_ID"] = "plan_test"
    ENV["WHOP_RETURN_URL"] = "https://example.test/return"
    Rails.cache.clear
  end

  def begin_demo(browser = self)
    browser.get "/"
    token = Nokogiri::HTML(browser.response.body).at_css("meta[name=csrf-token]")["content"]
    browser.post "/session", params: {authenticity_token: token}
    browser.follow_redirect!
  end

  def csrf_token
    css_select("meta[name=csrf-token]").first["content"]
  end

  test "visitors can read the playground without creating customers" do
    assert_no_difference "User.count" do
      get "/"
      assert_response :ok
      assert_select "button", "Start your sandbox session →"
    end
    post "/checkout", params: {authenticity_token: csrf_token}
    assert_redirected_to "/"
    assert_empty Pay::Whop::Charge.all
  end

  test "checkout creates a private session link and does not grant access" do
    request = api(:post, "checkout_configurations", {id: "ch_test", purchase_url: "https://sandbox.whop.com/checkout/test"})
    begin_demo
    post "/checkout", params: {authenticity_token: csrf_token}
    assert_redirected_to "https://sandbox.whop.com/checkout/test"
    get "/"
    post "/checkout", params: {authenticity_token: csrf_token}
    assert_requested request, times: 1
    assert_empty Pay::Whop::Subscription.all
    assert_empty Pay::Whop::Charge.all
  end

  test "another visitor cannot see or mutate a customer's billing" do
    begin_demo
    owner = User.order(:id).last.payment_processor
    subscription = owner.subscriptions.create!(name: "default", processor_id: "mem_private", processor_plan: "plan_test", status: "active", quantity: 1)
    charge = owner.charges.create!(processor_id: "pay_private", amount_refunded: 0, amount: 1000, currency: "usd")
    stranger = open_session
    begin_demo(stranger)
    refute_includes stranger.response.body, "mem_private"
    refute_includes stranger.response.body, "pay_private"
    token = Nokogiri::HTML(stranger.response.body).at_css("meta[name=csrf-token]")["content"]
    stranger.post "/subscriptions/#{subscription.id}/cancel", params: {authenticity_token: token}
    assert_equal 404, stranger.response.status
    stranger.post "/charges/#{charge.id}/refund", params: {authenticity_token: token}
    assert_equal 404, stranger.response.status
    assert_equal "active", subscription.reload.status
    assert_equal 0, charge.reload.amount_refunded
  end

  test "session creation rejects missing CSRF tokens" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    assert_no_difference "User.count" do
      post "/session"
      assert_response :unprocessable_entity
    end
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "health endpoint works without a session" do
    get "/up"
    assert_response :ok
  end
  test "one-time and setup checkouts have independent cached links" do
    begin_demo
    api(:post, "checkout_configurations", {id: "ch_once", purchase_url: "https://sandbox.whop.com/checkout/once"})
      .with { |request| JSON.parse(request.body)["mode"] == "payment" }
    api(:post, "checkout_configurations", {id: "ch_setup", purchase_url: "https://sandbox.whop.com/checkout/setup"})
      .with { |request| JSON.parse(request.body)["mode"] == "setup" }
    post "/checkout", params: {flow: "one_time", authenticity_token: csrf_token}
    assert_redirected_to "https://sandbox.whop.com/checkout/once"
    get "/"
    post "/checkout", params: {flow: "setup", authenticity_token: csrf_token}
    assert_redirected_to "https://sandbox.whop.com/checkout/setup"
    assert_equal 2, User.order(:id).last.checkout_urls.size
  end

  test "unsupported checkout flows fail before calling Whop" do
    begin_demo
    post "/checkout", params: {flow: "anything", authenticity_token: csrf_token}
    assert_response :bad_request
  end

  test "a stranger cannot pause a subscription or select a foreign saved method" do
    @customer.update!(processor_id: "mber_private")
    subscription = @customer.subscriptions.create!(name: "default", processor_id: "mem_private", processor_plan: "plan_test", status: "active", quantity: 1)
    begin_demo
    post "/subscriptions/#{subscription.id}/pause", params: {authenticity_token: csrf_token}
    assert_response :not_found
    assert_not_requested :post, %r{memberships/mem_private/pause}
  end
end
