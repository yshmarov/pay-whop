module Pay
  module Whop
    class Merchant < Pay::Merchant
      has_many :transfers, class_name: "Pay::Whop::Transfer", dependent: :destroy

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
        result = Whop.client.accounts.create(email: email, title: title, **options, request_options: Whop.request_options(idempotency_key: idempotency_key))
        object = Whop.api_attributes(Whop.client.accounts.retrieve(id: result.id, request_options: Whop.request_options))
        raise IdentityError, "Account is not a child of this platform" unless object.dig("parent_account", "id") == Whop.account_id
        with_lock do
          raise IdentityError, "Merchant was already assigned" if processor_id.present? && processor_id != result.id
          update!(processor_id: result.id, data: data.to_h.merge("whop_platform_id" => Whop.account_id, "whop_environment" => Whop.environment))
        end
        result
      end

      def account
        verify_configuration!
        result = Whop.client.accounts.retrieve(id: processor_id, request_options: Whop.request_options)
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

      def account_link(refresh_url:, return_url:, use_case: "account_onboarding", idempotency_key: SecureRandom.uuid)
        account
        raise ArgumentError, "Invalid account link use case" unless %w[account_onboarding payouts_portal].include?(use_case)
        Whop.client.account_links.create(account_id: processor_id, refresh_url: refresh_url, return_url: return_url,
          use_case: use_case, request_options: Whop.request_options(idempotency_key: idempotency_key))
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
        result = Whop.client.transfers.create(type: "balance", origin_id: Whop.account_id, destination_id: processor_id,
          amount: Whop.major_units(amount, decimals: decimals), currency: currency, metadata: metadata,
          idempotence_key: idempotency_key, request_options: Whop.request_options(idempotency_key: idempotency_key))
        Transfer.sync(result.id, account_id: Whop.account_id)
      end

      def whop? = true
    end
  end
end
