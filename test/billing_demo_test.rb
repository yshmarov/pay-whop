require "test_helper"

class BillingDemoTest < ActionDispatch::IntegrationTest
  setup do
    ENV["DEMO_PASSWORD"] = "test-demo-password"
    ENV["WHOP_VARIANT_ID"] = "plan_test"
    ENV["WHOP_RETURN_URL"] = "https://example.test/return"
    User.create!(email: "demo@example.test")
    @auth = {"HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("demo", "test-demo-password")}
  end

  test "billing actions require authentication" do
    get "/"
    assert_response :unauthorized
    get "/", headers: @auth
    token = css_select("meta[name=csrf-token]").first["content"]
    post "/checkout", params: {authenticity_token: token}
    assert_response :unauthorized
  end

  test "billing shows pending state without claiming payment succeeded" do
    get "/", headers: @auth
    assert_response :ok
    assert_select "h1", "Whop payments, Rails conventions."
    assert_select "p", /No successful payment/
  end

  test "checkout redirects to the provider and does not grant subscription access" do
    api(:post, "checkout_configurations", {id: "ch_test", purchase_url: "https://sandbox.whop.com/checkout/test"})
    get "/", headers: @auth
    token = css_select("meta[name=csrf-token]").first["content"]
    post "/checkout", params: {authenticity_token: token}, headers: @auth
    assert_redirected_to "https://sandbox.whop.com/checkout/test"
    assert_empty Pay::Whop::Subscription.all
    assert_empty Pay::Whop::Charge.all
  end
end
