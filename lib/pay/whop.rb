require "rails"
require "pay"
require "whop_sdk"
require "whop_sdk/helpers/verify_webhook"
require "bigdecimal"
require "net/http"
require "pay/whop/version"

module Pay
  module Whop
    class Error < Pay::Error; end
    class ConfigurationError < Error; end
    class IdentityError < Error; end
    class InvalidPayload < Error; end

    class PaymentIncomplete < Error
      attr_reader :payment

      def initialize(payment)
        @payment = payment
        super("Whop payment #{payment.id} is #{payment.status}; payment is not confirmed")
      end
    end

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

    def self.identity_purpose(account = account_id)
      "pay-whop:#{environment}:#{account}"
    end

    def self.api_attributes(object)
      JSON.parse(object.to_h.to_json)
    end

    def self.verify_account!(object, expected: nil)
      actual = object["account_id"] || object.dig("account", "id")
      raise IdentityError, "Whop account does not match resource" if expected && actual != expected
      registered = actual.present? && (actual == account_id || Merchant.registered?(actual))
      unless registered
        raise IdentityError, "Whop account is not registered with this platform"
      end
      actual
    end

    def self.major_units(amount, decimals: 2)
      raise ArgumentError, "Amount must be positive integer minor units" unless amount.is_a?(Integer) && amount.positive?
      raise ArgumentError, "Invalid currency precision" unless decimals.is_a?(Integer) && (0..8).cover?(decimals)
      value = BigDecimal(amount.to_s) / (10**decimals)
      number = value.to_f
      raise ArgumentError, "Amount exceeds JSON number precision" unless number.finite? && BigDecimal(number.to_s) == value
      number
    end

    def self.each_page(endpoint, **filters)
      endpoint.list(**filters, first: 100, request_options: request_options).each do |object|
        yield api_attributes(object)
      end
    end

    # SDK 2.7 truncates refund decimals and ignores additional_body_parameters.
    def self.api_request(method, path, body: nil, idempotency_key: nil)
      validate_configuration!
      host = (environment == "sandbox") ? "sandbox-api.whop.com" : "api.whop.com"
      uri = URI::HTTPS.build(host: host, path: "/api/v1/#{path}")
      request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Api-Version-Date"] = api_version
      request["Content-Type"] = "application/json"
      request["Idempotency-Key"] = idempotency_key if idempotency_key
      request.body = JSON.generate(body) if body
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = http.read_timeout = http.write_timeout = 20
      http.max_retries = 0
      response = http.start { |connection| connection.request(request) }
      unless response.is_a?(Net::HTTPSuccess)
        error = ::Whop_sdk::Errors::ResponseError.subclass_for_code(response.code.to_i)
        raise error.new(response.body, code: response.code.to_i)
      end
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
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
