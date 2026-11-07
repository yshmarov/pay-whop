require "mail"
Pay.enabled_processors = []
Pay.send_emails = false
Pay.support_email = "demo@example.test"
Pay.application_name = "pay-whop demo"
Pay::Whop.configure do |config|
  config.api_key = ENV["WHOP_API_KEY"]
  config.account_id = ENV["WHOP_ACCOUNT_ID"]
  config.webhook_secret = ENV["WHOP_WEBHOOK_SECRET"]
  config.environment = ENV.fetch("WHOP_ENVIRONMENT", "sandbox")
end
raise "The playground only supports Whop sandbox" unless Pay::Whop.environment == "sandbox"
