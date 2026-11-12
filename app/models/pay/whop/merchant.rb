module Pay
  module Whop
    class Merchant < Pay::Merchant
      has_many :transfers, class_name: "Pay::Whop::Transfer", dependent: :destroy
      has_many :payouts, class_name: "Pay::Whop::Payout", dependent: :destroy

      def self.registered?(account)
        where(processor_id: account).any? { |merchant| merchant.configured? }
      end

      def configured?
        data.to_h.values_at("whop_platform_id", "whop_environment") == [Whop.account_id, Whop.environment]
      end

      def verify_configuration!
        raise IdentityError, "Merchant belongs to another platform or environment" unless configured? && processor_id.present?
      end

      def create_account(email:, title:, idempotency_key: "pay-whop-merchant-#{id}", **options)
        return account if processor_id.present?
        raise ArgumentError, "Unknown account option" unless (options.keys - %i[country website metadata send_customer_emails]).empty?
        result = Whop.api.accounts.create(email: email, title: title, **options, request_options: Whop.request_options(idempotency_key: idempotency_key))
        object = Whop.api_attributes(Whop.api.accounts.retrieve(id: result.id, request_options: Whop.request_options))
        raise IdentityError, "Account is not a child of this platform" unless object.dig("parent_account", "id") == Whop.account_id
        with_lock do
          raise IdentityError, "Merchant was already assigned" if processor_id.present? && processor_id != result.id
          update!(processor_id: result.id, data: data.to_h.merge("whop_platform_id" => Whop.account_id, "whop_environment" => Whop.environment))
        end
        result
      end

      def account
        verify_configuration!
        result = Whop.api.accounts.retrieve(id: processor_id, request_options: Whop.request_options)
        object = Whop.api_attributes(result)
        unless object.fetch("id") == processor_id && object.dig("parent_account", "id") == Whop.account_id
          raise IdentityError, "Account is not a child of this platform"
        end
        result
      end

      def self.sync(id, account_id:)
        raise IdentityError, "Account event does not match its resource" unless [Whop.account_id, id].include?(account_id)
        merchant = find_by!(processor_id: id)
        object = Whop.api_attributes(merchant.account)
        merchant.with_lock do
          merchant.update!(data: merchant.data.to_h.merge("status" => object["status"], "capabilities" => object["capabilities"]))
        end
        merchant
      end

      def account_link(refresh_url:, return_url:, use_case: "account_onboarding", type: nil, idempotency_key: SecureRandom.uuid)
        account
        use_case = type if type
        raise ArgumentError, "Invalid account link use case" unless %w[account_onboarding payouts_portal].include?(use_case)
        Whop.api.account_links.create(account_id: processor_id, refresh_url: refresh_url, return_url: return_url,
          use_case: use_case, request_options: Whop.request_options(idempotency_key: idempotency_key))
      end

      def login_link(refresh_url:, return_url:, **options)
        account_link(refresh_url: refresh_url, return_url: return_url, use_case: "payouts_portal", **options)
      end

      def readiness
        object = Whop.api_attributes(account)
        {"status" => object["status"], "capabilities" => object["capabilities"],
         "required_actions" => Array(object["required_actions"]).map { |action| action.slice("action", "status", "blocked_capabilities", "cta") }}
      end

      def capability_active?(name)
        readiness.fetch("capabilities", {}).to_h[name.to_s] == "active"
      end

      def onboarding_complete?(capabilities: %w[accept_card_payments])
        state = readiness
        state["status"] == "active" && capabilities.present? && capabilities.all? { |name| state["capabilities"].to_h[name.to_s] == "active" }
      end

      def balance
        verify_configuration!
        object = Whop.api_request(:get, "ledger_accounts/#{ERB::Util.url_encode(processor_id)}")
        raise IdentityError, "Ledger belongs to another account" unless object.dig("owner", "id") == processor_id
        object.fetch("balances").map do |balance|
          balance.slice("currency", "balance", "pending_balance", "reserve_balance").transform_values { |value| value.is_a?(Numeric) ? BigDecimal(value.to_s) : value }
        end
      end

      def reconcile!
        account
        counts = {transfers: 0, payouts: 0}
        Whop.each_api_page("transfers", origin_id: Whop.account_id, destination_id: processor_id) do |object|
          unless object.dig("origin", "id") == Whop.account_id && object.dig("destination", "id") == processor_id
            raise IdentityError, "Transfer belongs to another merchant"
          end
          Transfer.sync(object.fetch("id"), account_id: Whop.account_id)
          counts[:transfers] += 1
        end
        Whop.each_api_page("payouts", account_id: processor_id) do |object|
          Payout.sync_object(object, merchant: self)
          counts[:payouts] += 1
        end
        counts
      end

      def customer_for(owner)
        verify_configuration!
        owner.with_lock do
          existing = owner.pay_customers.where(type: "Pay::Whop::Customer", deleted_at: nil).detect { |customer| customer.account_id == processor_id && customer.data.to_h["whop_environment"] == Whop.environment }
          existing || owner.pay_customers.create!(type: "Pay::Whop::Customer", processor: "whop", default: false,
            data: {whop_account_id: processor_id, whop_environment: Whop.environment})
        end
      end

      def transfer(amount:, idempotency_key:, currency: "usd", decimals: 2, metadata: {})
        account
        result = Whop.api.transfers.create(type: "balance", origin_id: Whop.account_id, destination_id: processor_id,
          amount: Whop.major_units(amount, decimals: decimals), currency: currency, metadata: metadata,
          idempotence_key: idempotency_key, request_options: Whop.request_options(idempotency_key: idempotency_key))
        Transfer.sync(result.id, account_id: Whop.account_id)
      end

      def whop? = true
    end
  end
end
