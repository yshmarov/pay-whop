require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"
require "active_job/railtie"
Bundler.require(*Rails.groups)

module PayWhopDemo
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults 8.1
    config.active_record.maintain_test_schema = false
    config.secret_key_base = Rails.env.production? ? ENV.fetch("SECRET_KEY_BASE") : ENV.fetch("SECRET_KEY_BASE", "local-pay-whop-demo-" * 8)
    config.hosts = ["localhost", "127.0.0.1", "www.example.com"]
    config.hosts << ENV["DEMO_HOST"] if ENV["DEMO_HOST"].present?
    config.hosts << ENV["RENDER_EXTERNAL_HOSTNAME"] if ENV["RENDER_EXTERNAL_HOSTNAME"].present?
    config.host_authorization = {exclude: ->(request) { request.path == "/up" }}
    config.eager_load = Rails.env.production?
    config.consider_all_requests_local = false
    config.active_job.queue_adapter = if Rails.env.production?
      :good_job
    else
      (Rails.env.test? ? :test : :async)
    end
    config.cache_store = :memory_store, {size: 16 * 1024 * 1024}
    config.session_store :cookie_store, key: "_pay_whop_playground", expire_after: 30 * 24 * 60 * 60, same_site: :lax, secure: Rails.env.production?
    config.force_ssl = Rails.env.production?
    config.assume_ssl = Rails.env.production?
    config.action_mailer.delivery_method = :test
    config.action_mailer.default_url_options = {host: "localhost", port: 3001}
    config.active_record.dump_schema_after_migration = false
    config.log_level = :warn
    config.filter_parameters += [:password, :token, :secret, :authorization, :pay_customer, :checkout_url]
  end
end
