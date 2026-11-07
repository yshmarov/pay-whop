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
end
