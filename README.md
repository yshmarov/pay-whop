# pay-whop

Whop payments, recurring billing and marketplace subaccounts for [Pay](https://github.com/pay-rails/pay), the Ruby on Rails payments engine.

**[Try the public sandbox demo →](https://pay-whop.onrender.com/)** — one-time payments, subscriptions, marketplace fees, saved methods and refunds with test money. Free hosting can take about a minute to wake up.

The demo also includes **[invoice and transfer simulations](https://pay-whop.onrender.com/#simulations)**. Start a browser session, then try invoice issuance, overdue/payment/void outcomes and transfer success/failure. No Whop account or KYC is needed for these controls. They update separate demo records with `sim_` references and a visible activity history; they never call Whop, create Pay charges, grant subscription access or generate provider webhooks. Reset each flow to try another outcome. These simulations do not certify real invoice issuance or transfer settlement.

**Early community adapter, not an official Whop or Pay integration.** Start in Whop's sandbox. The alpha supports direct billing and registered Whop subaccounts. Use one platform account and one environment per Rails database.

```ruby
user.set_payment_processor(:whop)

checkout = user.payment_processor.checkout(
  variant_id: "plan_...",
  redirect_url: billing_url,
  idempotency_key: checkout_attempt.id.to_s
)
redirect_to checkout.purchase_url, allow_other_host: true

# After Whop's verified webhook has been processed:
user.payment_processor.subscribed?
user.payment_processor.subscription.cancel
user.payment_processor.charges.last.refund!
```

## Status and scope

| Capability | Status |
| --- | --- |
| Hosted checkout for an existing Whop variant | Implemented |
| Link a Rails customer using signed checkout metadata | Implemented; never matched by email |
| Recurring membership and successful payment synchronization | Implemented |
| Cancel at period end, cancel immediately, reverse a pending cancellation | Implemented |
| Full and partial refunds | Implemented; exact partial refund verified in sandbox |
| Verified webhooks, duplicate record prevention, stale snapshot protection | Implemented |
| Trial and past-due state synchronization | Implemented; provider behavior still needs sandbox coverage |
| Pause/resume billing, one-time entitlements, free days and promo codes | Implemented; see provider-state caveats in the advanced guide |
| Saved methods, direct charging, authorization/capture/void | Implemented; saved-method charging verified in sandbox |
| Draft/issued invoices, invoice settlement and dispute workflows | Implemented; invoice issuance requires account verification |
| Subaccounts, onboarding/payout links, application fees, transfers | Implemented; settlement depends on provider capabilities and available balance |
| Existing-payment retry and 3DS recovery URL | Implemented; HTTP and demo error-path coverage |
| Reduce renewal price, change billing period or next renewal date | Implemented within Whop restrictions; HTTP coverage |
| Merchant capabilities, balances, payout status and reconciliation | Implemented; sandbox reads verified, bank payouts unavailable in sandbox |
| Application webhook callbacks and pending-delivery recovery job | Implemented |
| Plan swaps, proration, recurring seat changes, metered usage | Not supported |
| Seller isolation under one platform | Implemented; never mix sandbox and production in one database |
| One-time purchases | Implemented as Pay charges, not recurring subscriptions |

See the [compatibility matrix](docs/compatibility.md) and [advanced usage](docs/advanced-usage.md) for one-time purchases, saved cards, invoices, marketplace fees and payouts, and dispute workflows.

Unsupported adapter operations raise `Pay::NotSupportedError`. The SDK remains available through `Pay::Whop.client`, but SDK calls alone do not synchronize Pay records.

Requires Ruby 3.3+, Pay 12.3–12.x, and `whop_sdk` 2.7.x. The bundled demo uses Rails 8.1. API requests and webhook registration use the dated API version `2026-10-28-1`. The current [RubyGems alpha is `0.1.0.alpha.4`](https://rubygems.org/gems/pay-whop/versions/0.1.0.alpha.4).

## Install in a Rails application

Install the published alpha from RubyGems:

```ruby
# Gemfile
gem "pay-whop", "0.1.0.alpha.4"
```

Install both engines' migrations, including Pay's STI and object-column migrations:

```sh
bundle install
bin/rails pay:install:migrations
bin/rails pay_whop:install:migrations
bin/rails db:migrate
```

Configure the adapter in an initializer. Keep credentials outside version control:

```ruby
Pay::Whop.configure do |config|
  config.environment = ENV.fetch("WHOP_ENVIRONMENT", "sandbox")
  config.api_key = ENV.fetch("WHOP_API_KEY")
  config.account_id = ENV.fetch("WHOP_ACCOUNT_ID")
  config.webhook_secret = ENV.fetch("WHOP_WEBHOOK_SECRET")
end
```

Configure your billable model as usual:

```ruby
class User < ApplicationRecord
  pay_customer
end
```

The gem mounts `POST /pay/whop/webhooks`. For marketplaces, enable subaccount events on the platform webhook. Register a webhook on the same Whop account and API version, using the event names in `Pay::Whop::Delivery::EVENTS`. Supply its signing secret verbatim, including the `ws_` prefix.

Use an Account API key with permissions for checkout configuration creation, member reads, membership reads/updates/cancellation, and payment reads/refunds. Product/variant and webhook-management permissions are needed only if your application provisions those resources. Whop's sandbox Admin role can create checkouts; its `accounts.me` endpoint additionally requires balance-read access, so the connection checker deliberately uses the checkout API.

Run an Active Job worker. Production needs a durable queue adapter. The example uses PostgreSQL-backed GoodJob in production and the in-memory `:async` adapter for local development.

## How synchronization works

1. Checkout metadata contains a signed Pay customer ID, scoped to the seller account and environment. Treat the customer-specific checkout URL as private: Whop checkout configurations are reusable links, not single-use sessions.
2. The webhook endpoint verifies Whop's signature and timestamp, checks the seller account, then persists the event ID, type and resource ID. It does not persist the raw webhook body.
3. A job retrieves the current payment or membership from Whop. It verifies the account again and resolves the signed customer reference or an already-linked Whop member.
4. Pay records are updated under a customer row lock. Provider `updated_at` values prevent older snapshots from overwriting newer ones. API calls run outside database transactions.
5. Payment records become Pay charges only when their provider status is `paid`. A checkout redirect, pending payment or authorized card is not a paid charge.

A Whop member can belong to only one Pay customer in this application. Conflicting links fail explicitly. Marketplace buyers use separate seller-scoped customer records created by `merchant.customer_for(user)`; changing the configured platform or environment requires a separate database.

Duplicate webhook jobs may run, but synchronization does not create duplicate charges or subscriptions. This is not an exactly-once notification system. This version does not send Pay receipts or subscription emails; Whop's own messaging settings remain in effect.

Deliveries remain pending if processing fails. Network, rate-limit and server errors receive bounded Active Job retries; other API failures emit `delivery_failed.pay_whop` without retrying that job automatically. After fixing a persistent error, enqueue retained deliveries again:

```ruby
Pay::Whop::RecoverDeliveriesJob.perform_later
```

Schedule that recovery job periodically (it defaults to deliveries older than two minutes, with no one-day cutoff): a process can stop after the database write but before job enqueue. Monitor failed jobs rather than treating an HTTP 200 webhook acknowledgment as completed synchronization. Completed delivery IDs are retained for deduplication; choose a retention policy before running at scale.

## Billing differences

- Whop variants map to Pay's `processor_plan`, memberships to subscriptions, members to customers, and payments to charges.
- A scheduled cancellation retains access through the current billing period. `resume` reverses that scheduled cancellation; it does not reactivate an ended subscription.
- `refund!` asks Whop to refund the remaining balance, or the specified integer minor-unit amount, then retrieves current payment and membership state. Refunds settle asynchronously and do not themselves cancel a subscription; cancel separately when access should end. Insufficient seller funds raise `Pay::Whop::ApiError` and leave the local refund amount unchanged.
- Pay stores integer minor units. Whop money objects are converted with `BigDecimal` and the provider's currency precision, without rounding fractions away.
- Amounts currently use Whop's account-facing `total` and `refunded_amount`, not buyer fees. Currency mismatches are rejected; adaptive-pricing/FX refunds and tax reconciliation require further validation before enabling them.
- Supply a stable `idempotency_key:` for each checkout, charge, cancellation, resumption, invoice, transfer or refund attempt. Reuse it when retrying the same operation after a timeout. A new operation needs a new key. SDK automatic retries are disabled so unexamined writes are not automatically repeated.

## Run the example

```sh
bundle install
cp .env.example .env
# Fill in sandbox credentials, an existing recurring WHOP_VARIANT_ID,
# never commit .env.
bundle exec bin/sandbox-check
bundle exec examples/rails/bin/setup
cd examples/rails
bundle exec bin/rails server -b 127.0.0.1 -p 3001
```

Open `http://localhost:3001` and start a sandbox session. Each browser gets its own synthetic customer in an encrypted session cookie; all billing actions are scoped to that customer. Reuse the same browser session with your Whop sandbox account. The public playground requires PostgreSQL and a secret key; its development secret key cannot be used in production. This example is not a production SaaS starter.

Whop requires an HTTPS checkout return URL. Set `WHOP_RETURN_URL` to an HTTPS page you control; for local testing it can be a static page that links back to localhost. Expose only the webhook route through your local tunnel, register that HTTPS URL in Whop, and set `WHOP_WEBHOOK_SECRET` before restarting the server. Checkout returns to the billing page; refresh after the webhook arrives. A successful subscription, cancellation and refund should be visible in both Pay and Whop.

Recover pending local deliveries with:

```sh
bundle exec examples/rails/bin/reconcile
```

## Deploy the playground

`render.yaml` defines a free Rails web service. Supply a separate persistent PostgreSQL database (for example, Neon Free); Render’s free database expires after 30 days. The app uses GoodJob with PostgreSQL-backed jobs, bounded retries and a recovery job for pending deliveries. It only boots against Whop sandbox. Free hosting has usage limits and the web service sleeps when idle.

Set the listed environment variables in the host’s secret settings. Optionally set `DEMO_MERCHANT_ID` to a registered sandbox subaccount to show marketplace checkout, and `WHOP_ONE_TIME_VARIANT_ID` to a USD 5.00 one-time variant to show draft invoices. Set `WHOP_RETURN_URL` to the public HTTPS root URL, register `/pay/whop/webhooks` with Whop using the adapter’s event list and dated API version, then set `WHOP_WEBHOOK_SECRET`. `examples/rails/bin/start` applies migrations and starts Puma. Keep a stable `SECRET_KEY_BASE`: changing it invalidates sessions and the customer references already stored in Whop.

Never expose the local developer database or reuse a production Whop API key for this demo. The public app has no admin interface and never accepts visitor API keys.

## Develop

```sh
bin/test
# Or:
bundle exec rake test
bundle exec standardrb
```

The tests use a real Rails application and Pay models, WebMock at the HTTP boundary, and genuinely signed webhook requests. They require no credentials and block external network calls. CI covers Ruby 3.3/3.4/4.0 × Pay 12.3.0/12.4.0 × SQLite/PostgreSQL. `TEST_DATABASE_URL=postgresql://localhost/pay_whop_test bundle exec rake test` uses a temporary schema in a dedicated database ending in `_test`. Run `bundle exec ruby bin/install-smoke` to build the gem, extract it and install/migrate/boot a fresh Rails application. See [release instructions](docs/releasing.md). See [verification notes](docs/verification.md) for tested versions and sandbox evidence.

## References

- [Pay processor guide](https://github.com/pay-rails/pay/blob/main/docs/contributing/adding_a_payment_processor.md)
- [Whop sandbox quickstart](https://docs.whop.com/developer/quickstart)
- [Whop Ruby SDK](https://github.com/whopio/whopsdk-ruby)
- [Whop webhook verification](https://docs.whop.com/developer/guides/webhooks)
- [Whop API stability](https://docs.whop.com/api-reference/stability)

MIT license. Contributions welcome.
