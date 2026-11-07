require "rails"
require "pay"
require "whop_sdk"
require "whop_sdk/helpers/verify_webhook"
require "bigdecimal"
require "pay/whop/version"

module Pay
  module Whop
    class Error < Pay::Error; end
    class ConfigurationError < Error; end
    class IdentityError < Error; end
    class InvalidPayload < Error; end

    mattr_accessor :api_key, :account_id, :webhook_secret
    mattr_accessor :environment, default: "sandbox"
    mattr_accessor :api_version, default: "2026-10-28-1"
    mattr_accessor :queue_name, default: :default

    def self.configure
      yield self
    end

    def self.validate_configuration!
      raise ConfigurationError, "Set Pay::Whop.api_key" if api_key.blank?
      raise ConfigurationError, "Set Pay::Whop.account_id" if account_id.blank?
      raise ConfigurationError, "Whop environment must be sandbox or production" unless %w[sandbox production].include?(environment)
    end

    def self.client
      validate_configuration!
      ::Whop_sdk::Client.new(
        token: api_key,
        environment: (environment == "sandbox") ? ::Whop_sdk::Environment::SANDBOX : ::Whop_sdk::Environment::PRODUCTION,
        api_version_date: api_version,
        max_retries: 0
      )
    end

    def self.request_options(idempotency_key: nil)
      {timeout_in_seconds: 20, additional_headers: {"Idempotency-Key" => idempotency_key}.compact}
    end

    def self.identity_purpose
      "pay-whop:#{environment}:#{account_id}"
    end

    def self.api_attributes(object)
      JSON.parse(object.to_h.to_json)
    end

    def self.verify_account!(object)
      actual = object["account_id"] || object.dig("account", "id")
      raise IdentityError, "Whop account does not match configuration" unless actual.present? && actual == account_id
    end

    def self.minor_units(money, currency: nil)
      raise InvalidPayload, "Missing Whop money object" unless money.is_a?(Hash)
      raise InvalidPayload, "Currency mismatch" if currency && money.fetch("currency").downcase != currency.downcase
      decimals = Integer(money.fetch("decimals"))
      raise InvalidPayload, "Invalid currency precision" unless (0..8).cover?(decimals)
      amount = BigDecimal(money.fetch("amount").to_s) * (10**decimals)
      raise InvalidPayload, "Money is not an exact minor-unit amount" unless amount.finite? && amount.frac.zero? && amount >= 0
      amount.to_i
    end

    def self.timestamp(value)
      Time.iso8601(value) if value.present?
    end
  end
end

require "pay/whop/engine"
