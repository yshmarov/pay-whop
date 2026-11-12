# Billing and marketplaces

All amounts accepted by adapter convenience methods are integer minor units: `500` means USD 5.00. Specify `decimals: 0` for JPY or `decimals: 3` for KWD when creating prices or transfers; refund precision comes from the original payment. Arbitrary inline `variant` prices follow Whop's API and use major units.

## One-time and recurring checkout

```ruby
customer = user.set_payment_processor(:whop)
checkout = customer.checkout_charge(
  amount: 500, currency: "usd", redirect_url: billing_url,
  idempotency_key: order.id.to_s
)
redirect_to checkout.purchase_url, allow_other_host: true

# Existing recurring variant:
customer.checkout(variant_id: "plan_...", redirect_url: billing_url)

# Inline recurring variant, including a trial:
customer.checkout(
  variant: {currency: "usd", billing_type: "renewal", renewal_price: 10,
            billing_period: 30, trial_period_days: 7, product_id: "prod_..."},
  redirect_url: billing_url
)
```

Successful one-time purchases become `Pay::Whop::Charge` records without a recurring subscription. They do not make `subscribed?` true. Your application fulfills the order after the verified payment is synchronized. An inline recurring variant's `initial_price` is an additional first-payment fee, not its recurring price.

## Saved methods and direct payments

```ruby
checkout = customer.setup_checkout(redirect_url: billing_url)
# Redirect the buyer; setup_intent.succeeded links the saved method.
customer.sync_payment_methods
customer.add_payment_method("payt_...", default: true)
charge = customer.charge(500, idempotency_key: order.id.to_s)
subscription = customer.subscribe(plan: "plan_...", name: "default")
```

The default is local to this adapter. It does not silently replace the payment method on existing Whop memberships. Use `subscription.update_payment_method("payt_...")` for that. `payment_method.detach` deletes the saved provider method after verifying it belongs to the linked member.

Direct payments can return before completion. `charge`, `subscribe`, `capture` and `retry_payment` raise `Pay::Whop::PaymentIncomplete` with an SDK `payment` object when it is not yet `paid`. Handle this as pending or buyer action required, not as a successful purchase or a reason to create another payment. Reuse the same idempotency key. Webhooks reconcile successful settlement.

```ruby
begin
  customer.charge(500, idempotency_key: order.id.to_s)
rescue Pay::Whop::PaymentIncomplete => error
  payment_id = error.payment.id
  if error.recovery_url
    redirect_to error.recovery_url, allow_other_host: true
  else
    # Present a pending state and await the verified webhook.
  end
end
```

For custom payment-element frontends, `create_payment_intent(confirmation_token:, return_url:, variant_id:)` and `create_setup_intent(confirmation_token:, return_url:)` attach the same signed identity metadata and return SDK objects. Render Whop's official elements and follow their authentication/status flow; never collect raw card numbers in Rails. These methods do not imply payment success or save a Pay charge themselves.

For authorizations, `customer.authorize(500, idempotency_key: ...)` returns the provider payment; `customer.capture(payment_id)` captures in full and reconciles it, while `customer.void(payment_id)` releases it. Whop must still accept the authorization/capture state and deadline. `customer.retry_payment(payment_id)` retries an existing payment; it does not create a new order.

## Refunds and subscriptions

```ruby
charge.refund!(100, idempotency_key: "refund-order-42-part-1") # USD 1.00
charge.refund!(idempotency_key: "refund-order-42-rest")       # remaining balance

subscription.pause                         # pause billing; retain paid-period access
subscription.pause(until_time: 1.week.from_now)
subscription.unpause                       # resume paused billing
subscription.cancel                        # cancel at period end
subscription.resume                        # undo scheduled cancellation or resume a pause
subscription.cancel_now!
subscription.add_free_days(7)
subscription.apply_promo_code(promo_code: "SAVE20")
subscription.update_payment_method("payt_...")
customer.billing_portal                    # existing membership's manage URL
customer.sync_subscriptions
```

A refund is separate from cancellation and can settle asynchronously. The adapter refreshes the provider's confirmed refunded amount, rather than setting it optimistically. Refund requests fail when funds or provider rules prevent them. SDK 2.7 types partial refunds as integers and ignores its advertised extra-body option; a small authenticated HTTP fallback sends the exact fractional amount and retains the pinned API date and idempotency key.

`paused?` describes billing collection. Access continues until the current paid period ends; both `active?` and Pay's active subscription query preserve that distinction. Whop exposes a pause through `most_recent_action == "paused_at"`, not a `paused` membership status. The adapter refreshes provider state after every mutation; it never reports a pause solely because the request returned HTTP 200.

Ended recurring subscriptions require a new checkout: Whop rejected recurring reactivation in sandbox. One-time product memberships are stored separately as `customer.entitlements`; their `active?` checks status and expiry, and `entitlement.reactivate(days: 30)` uses the one-time reactivation API.

```ruby
subscription.retry_failed_payment(idempotency_key: "retry-payment-42")
subscription.retry_failed_payment(payment_id: "pay_...", idempotency_key: "retry-payment-42")
subscription.reduce_renewal_price(855, idempotency_key: "discount-membership-42")
subscription.change_billing_period(90, idempotency_key: "cadence-membership-42")
subscription.change_next_renewal(60.days.from_now, idempotency_key: "renew-membership-42")
```

Retry resolves an existing payment belonging to this membership. Already-paid payments only synchronize; no new payment is created. A still-incomplete retry raises `PaymentIncomplete`. The returned `recovery_url` is limited to HTTPS on the configured Whop environment's host; only a confirmed provider payment creates a charge.

Renewal prices can only decrease, using the existing currency precision. Whop emails the buyer about a price reduction. Billing periods accept 1–365 days; next-renewal dates must be after today in UTC. Each change sends one field and then refreshes actual membership state. Whop additionally enforces eligibility (for example, active/trialing, recurring, unpaused, auto-billed memberships for price reductions, and restrictions on invoice billing, cancellation and daily cadence). These changes are not arbitrary plan swaps or Stripe-style proration. Provider rejection leaves local state unchanged. New renewal controls have HTTP-contract tests, not completed provider billing-cycle validation.

Plan swaps, proration, recurring seat changes and usage metering are not implemented. Whop's `swaps` resource converts currencies; it is not a subscription-plan swap API.

## Invoices

```ruby
invoice = customer.create_invoice(items: [{variant_id: "plan_...", quantity: 1}])
invoice.issue
invoice.checkout_url
invoice.pdf_url
invoice.charge(payment_method_id: "payt_...")
invoice.void
invoice.mark_uncollectible
invoice.unschedule
invoice.update_details(memo: "Order 42", due_at: 7.days.from_now)
invoice.deliver # Explicitly sends Whop's invoice email; only call when intended.

# Create and issue in one call, with separate stable creation/issue keys:
customer.invoice!(items: [{variant_id: "plan_...", quantity: 1}], idempotency_key: "invoice-42")
```

Invoice records store a billing summary, not the buyer's address or email. Only a paid invoice creates a Pay charge. Issuing or charging can require verified account capabilities. The demo account can create drafts but Whop currently blocks issuance until account verification is completed. No invoice emails were sent during verification.

## Marketplace / Connect-style flows

Configure the platform's Account API key and account ID normally. Add `pay_merchant` to your seller model:

```ruby
class Seller < ApplicationRecord
  pay_merchant
end

merchant = seller.set_merchant_processor(:whop)
merchant.create_account(email: seller.email, title: seller.name,
                        idempotency_key: "seller-#{seller.id}")
link = merchant.account_link(refresh_url: onboarding_url, return_url: sellers_url)
# Redirect the seller to link.url for Whop's onboarding/KYC.
payouts = merchant.account_link(use_case: "payouts_portal",
                              refresh_url: onboarding_url, return_url: sellers_url)

buyer = merchant.customer_for(user)
checkout = buyer.checkout_charge(amount: 500, application_fee_amount: 100,
                                 redirect_url: billing_url, idempotency_key: order.id.to_s)

# Alternatively collect on the platform, then transfer to the seller:
transfer = merchant.transfer(amount: 400, currency: "usd", idempotency_key: "seller-share-42")
transfer.status # processing, succeeded or failed; creation is not settlement
```

`customer_for` creates a separate seller-scoped Pay customer without replacing the user's default payment processor. Never switch the global account ID per request. The adapter trusts only the configured platform and locally registered subaccounts whose parent was checked through Whop's API. Member references are signed per environment and seller account; webhook envelope and fetched resource accounts must agree. Reuse one environment per database.

Register the platform webhook with **subaccount events enabled** and all events in `Pay::Whop::Delivery::EVENTS`. The platform signing secret verifies those child deliveries. Successful transfers are recorded separately from Pay charges. Whop requires sufficient available funds and may require identity verification for transfers or payouts; the adapter does not bypass those requirements or mark rejected transfers successful.

`account.updated` stores the subaccount's status/capability summary. `merchant.readiness` retrieves status, capabilities and required actions. `merchant.capability_active?(:transfer)` checks one capability. `merchant.onboarding_complete?` requires an active account with card payments enabled; pass `capabilities: %w[transfer]` or another explicit list for a different workflow. This does not imply every payout method is enabled. Unknown or missing capabilities are unavailable. Account creation and redirects alone do not satisfy these checks.

```ruby
merchant.readiness
merchant.balance # currency + BigDecimal balance/pending_balance/reserve_balance, in major units
merchant.login_link(refresh_url: onboarding_url, return_url: sellers_url) # hosted payouts portal
merchant.reconcile! # {transfers: ..., payouts: ...}
merchant.payouts.each { |payout| payout.sync! }
```

Payout status is synchronized through the authenticated account-filtered list, including pagination. Whop's public payout tracking endpoint is not used to establish ownership. Platform payout events also synchronize without inventing a seller: use `Pay::Whop::Payout.where(account_id: Pay::Whop.account_id, environment: Pay::Whop.environment)` from an authorized platform-administration context. Payout records retain decimal-string amount/fee summaries in `data`, without bank details; these are major units, unlike Pay charge amounts. A completed payout may later reverse. This adapter delegates bank withdrawal initiation to Whop's hosted portal; it does not implement payout quotes or direct bank withdrawal creation. [Whop documents that payouts are unavailable in sandbox](https://docs.whop.com/developer/guides/sandbox). Sandbox tests therefore do not prove bank settlement.

## Disputes

Verified dispute webhooks create `Pay::Whop::Dispute` records tied to the original charge's customer. They retain status, reason, due date and payment ID, not the buyer or submitted evidence.

```ruby
dispute.update_evidence(evidence: {product_description: "Digital course"})
dispute.upload_evidence(documents: [{document_type: "...", direct_upload_id: "..."}])
dispute.submit # Send the prepared evidence to Whop.
# Or explicitly accept the dispute:
dispute.accept
```

Use the current SDK/OpenAPI document schema for evidence fields. Disputes were tested with synthetic HTTP fixtures, not by creating a real chargeback.

## Permissions and operations

Use custom scopes for the features you enable: checkout read/create; product/plan read/create for inline prices; member read and payment-method read/manage/charge; membership update/cancel; payment read/charge/manage; invoice read/create/update; setup-intent read/manage; dispute read/manage; payout-account read/update; and the relevant webhook receive scopes. Platform account inspection additionally requires `company:balance:read`.

Hosted onboarding/payout links delegate a bundle of financial scopes. Whop required payout destination create/read/update/delete, withdrawal read/export/withdraw, transfer read/export/create, and balance read/export in the tested sandbox. Missing scopes produce an explicit API error. Webhook-management access is needed only by provisioning tools. Use separate provisioning/runtime credentials in a production deployment if your workflow allows it.

Use a durable Active Job adapter, retain receipt IDs for replay protection, monitor pending deliveries and choose a retention policy. The demo uses PostgreSQL-backed GoodJob. Applications should scope invoice/dispute/transfer lookups through the authenticated customer or merchant; the adapter does not provide authentication for your own controllers.

## Errors, callbacks and recovery

Adapter API calls raise `Pay::Whop::ApiError < Pay::Error`, exposing `status`, provider `code`, `retryable?` and the original `provider_error`/cause. Network timeouts have no HTTP status. A timeout may follow a successful provider write: reuse the operation's idempotency key and reconcile before creating a replacement. `Pay::Whop.client` deliberately remains the raw official SDK and raises its native errors.

```ruby
Pay::Webhooks.configure do |events|
  events.subscribe "whop.payment.succeeded" do |event|
    delivery = event.fetch(:delivery)
    # Billing state is already synchronized. Fulfill idempotently using delivery.event_id.
  end
end

Pay::Whop::RecoverDeliveriesJob.perform_later
customer.reconcile! # {memberships: ..., payments: ..., invoices: ..., skipped: ...}
```

Callbacks run after resource synchronization and before marking a delivery processed. Handler failure keeps the delivery pending; callbacks may repeat. They receive a delivery record containing IDs, not a captured provider payload. Retrieve application-owned records through the appropriate customer/merchant scope.

Customer reconciliation requires an already-linked member. It paginates that account/member's memberships, payments and invoices, and verifies resource identity before import. Unverifiable signed references (for example, another app's checkout on the same account) are skipped, counted and reported through `reconciliation_skipped.pay_whop`; they are never matched by email or silently reassigned. Preserve the Rails signing secret and investigate skips for known records after key rotation. This is not a global import of unrelated Whop customers. Reconciliation and missed-delivery recovery are separate operations; schedule both as appropriate for your application.

Monitor `delivery_failed.pay_whop` (delivery ID, HTTP status and provider code) and retained pending deliveries. The recovery job can re-enqueue failures after the underlying problem is fixed; periodic recovery will also encounter persistent errors, so alert on them rather than hiding them.
