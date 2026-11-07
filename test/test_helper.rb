ENV["RAILS_ENV"] = "test"
require_relative "../examples/rails/config/environment"
require "rails/test_help"
require "webmock/minitest"
require "minitest/mock"

WebMock.disable_net_connect!(allow_localhost: true)
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table(:users, force: true) { |t|
    t.string :email
    t.timestamps
  }
end
pay_path = Gem::Specification.find_by_name("pay").full_gem_path
require "#{pay_path}/db/migrate/1_create_pay_tables"
require "#{pay_path}/db/migrate/2_add_pay_sti_columns"
require "#{pay_path}/db/migrate/20250415151129_add_object_to_pay_models"
require_relative "../db/migrate/20261107000000_create_pay_whop_deliveries"
CreatePayTables.new.migrate(:up)
AddPayStiColumns.new.migrate(:up)
AddObjectToPayModels.new.migrate(:up)
CreatePayWhopDeliveries.new.migrate(:up)

class ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Pay::Whop.configure do |config|
      config.api_key = "test_api_key"
      config.account_id = "biz_test"
      config.environment = "sandbox"
      config.webhook_secret = "ws_test_secret"
    end
    @user = User.create!(email: "test@example.test")
    @customer = @user.set_payment_processor(:whop,
      data: {whop_account_id: "biz_test", whop_environment: "sandbox"})
  end

  def api(method, path, response, body: nil, status: 200)
    stub = stub_request(method, "https://sandbox-api.whop.com/api/v1/#{path}")
      .with(headers: {"Authorization" => "Bearer test_api_key", "Api-Version-Date" => "2026-10-28-1"})
    stub = stub.with(body: body) if body
    stub.to_return(status: status, body: response.to_json, headers: {"Content-Type" => "application/json"})
  end

  def money(amount, currency = "usd", decimals = 2)
    {"amount" => amount, "currency" => currency, "decimals" => decimals, "display_decimals" => decimals}
  end

  def membership(**changes)
    {
      "id" => "mem_test", "account" => {"id" => "biz_test"}, "member_id" => "mber_test",
      "metadata" => {"pay_customer" => @customer.signed_id(purpose: Pay::Whop.identity_purpose)},
      "variant_id" => "plan_test", "status" => "active", "cancel_at_period_end" => false,
      "renewal_price" => money("10.00"), "initial_price" => money("10.00"),
      "created_at" => "2026-11-01T00:00:00Z", "updated_at" => "2026-11-07T00:00:00Z",
      "current_period_start" => "2026-11-01T00:00:00Z", "current_period_end" => "2027-12-01T00:00:00Z"
    }.merge(changes.stringify_keys)
  end

  def payment(**changes)
    {
      "id" => "pay_test", "account_id" => "biz_test", "member_id" => "mber_test",
      "metadata" => {"pay_customer" => @customer.signed_id(purpose: Pay::Whop.identity_purpose)},
      "membership_id" => nil, "status" => "paid", "total" => money("10.43"),
      "refunded_amount" => money("0.00"), "created_at" => "2026-11-01T00:00:00Z",
      "paid_at" => "2026-11-01T00:00:00Z", "updated_at" => "2026-11-07T00:00:00Z"
    }.merge(changes.stringify_keys)
  end

  def sign_event(type: "payment.succeeded", id: "evt_test", data: {"id" => "pay_test"}, account: "biz_test", at: Time.now)
    event = {id: id, type: type, account_id: account, data: data}
    body = event.to_json
    signature = StandardWebhooks::Webhook.new(Base64.strict_encode64(Pay::Whop.webhook_secret)).sign(id, at.to_i, body)
    [body, {"CONTENT_TYPE" => "application/json", "HTTP_WEBHOOK_ID" => id, "HTTP_WEBHOOK_TIMESTAMP" => at.to_i.to_s, "HTTP_WEBHOOK_SIGNATURE" => signature}]
  end
end
