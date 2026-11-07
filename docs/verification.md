# Verification

Verification date: 7 November 2026.

## Versions exercised

- Ruby 4.0.9
- Rails 8.1.4.1
- Pay 12.4.0
- Whop Ruby SDK 2.7.0
- Whop API version `2026-10-28-1`
- SQLite 2.10.2 gem

GitHub Actions passed tests and Standard Ruby linting on Ruby 3.3, 3.4 and 4.0 on Linux: [public playground CI run](https://github.com/yshmarov/pay-whop/actions/runs/42361431644), 7 November 2026.

## Automated coverage

Local result: 30 tests, 100 assertions, zero failures or errors. Standard Ruby linting and Rails eager loading pass. The alpha gem builds successfully.

The suite exercises the actual SDK HTTP boundary with WebMock, Rails routing, Active Job enqueueing and Pay's real models. It covers:

- Signed customer mapping and seller/environment isolation.
- Conflicting member-to-owner links and forged references.
- Payment-first delivery followed by membership synchronization.
- Duplicate delivery IDs, completed event replays and event-ID collisions.
- HMAC verification and rejection of expired signatures.
- Failed API calls leaving recoverable pending deliveries.
- Queue refusal returning HTTP 503 instead of pretending enqueue succeeded.
- Older provider snapshots failing to undo newer cancellation state.
- Period-end cancellation, immediate cancellation and reversal of pending cancellation.
- Pending/unpaid transactions not becoming Pay charges.
- Full refunds and currency mismatch rejection.
- Insufficient seller balance raising an error without marking a charge refunded.
- Exact money conversion for two-, zero- and three-decimal currencies.
- Isolated browser sessions, cross-customer read/action isolation, CSRF protection, idempotent checkout reuse and pending-payment presentation.

The fixtures are synthetic. They do not contain captured customer records or API credentials.

## Sandbox evidence

- Created a sandbox Account API key through the authenticated dashboard; stored locally outside version control.
- Authenticated against the checkout-configuration API.
- Created a hidden test product and recurring USD variant.
- Created a customer-specific hosted checkout using the adapter and signed Pay metadata.
- Registered the nine billing webhook events through the dashboard, pinned to the same API version as requests.
- Completed hosted checkout with Whop's documented test card: USD 24.00 (USD 10 initial fee, USD 10 first period and USD 4 tax). The API confirmed `paid`.
- Received the actual signed payment event through the public HTTPS endpoint; its background job created one 2,400-cent Pay charge and one active subscription.
- Verified scheduled cancellation retains access, resume clears the scheduled end, and immediate cancellation changes the subscription to canceled with no active access.
- Received membership events and processed all retained receipts with none pending.
- Attempted a full refund through the adapter. Whop returned `not_enough_balance`; the dashboard showed USD 17.83 entirely pending. The local charge correctly remained unrefunded. The charge remained unrefunded at that point. A later refund succeeded on the public deployment, as recorded below.

The first tunnel inherited an unrelated local Cloudflare ingress configuration and returned 404. Restarting with an explicit empty config corrected routing. Whop replayed the payment successfully with HTTP 200, and subsequent membership events arrived normally. This also exercised recovery after a real delivery failure.

## Public deployment evidence

The [public playground](https://pay-whop.onrender.com/) runs on Render Free with persistent PostgreSQL on Neon Free and GoodJob jobs stored in that database. It is sandbox-only. Free hosting sleeps when idle and is subject to provider usage limits.

- Completed a new hosted sandbox checkout from the public app and returned to the same browser session.
- Whop retried initial HTTP 500 deliveries after the signing-secret deployment finished; the payment and membership events then received HTTP 200 and completed in GoodJob.
- Confirmed one active subscription and one USD 24.00 charge in the public UI and PostgreSQL, with all received receipts processed.
- Scheduled cancellation through the public UI, verified the scheduled state, then resumed and verified active state with no scheduled end.
- Requested a full refund through the public UI. Whop's payment API reported USD 24.00 refunded, matching the persisted Pay charge and public display. Refund success is therefore verified in sandbox; pending seller funds can still block other refunds.
- Verified a separate hosted visitor cannot see the first visitor's billing records; cross-customer cancellation and refund requests return HTTP 404.
- Verified PostgreSQL migrations, production eager loading and persistent job execution. This is not a high-concurrency PostgreSQL stress test.
- Checked the playground layout at desktop and 390px mobile widths.

The earlier temporary tunnel was used only for local integration testing; the public demo has a stable hosted URL.

## Integration details discovered

1. Whop's documented sandbox Admin role does not grant `company:balance:read`, so `accounts.me` is unsuitable as a minimal adapter connectivity check. Checkout reads work with the same key.
2. The Admin key also lacks `developer:manage_webhook`. A seller can register webhooks through the dashboard without granting that permission to the running application.
3. Hosted checkout rejects HTTP return URLs, including localhost. The example therefore takes `WHOP_RETURN_URL` separately.
4. The SDK's default date is `2026-10-28`; the dashboard offers the precise version `2026-10-28-1`. Both requests and webhook configuration explicitly use the latter.
5. Under Rails, serializing an SDK model directly with `to_json` is not the same as serializing its API fields. The adapter converts via `to_h` first.
6. The current SDK types `partial_amount` as an integer while the API describes a currency-unit number. The first release supports full remaining-balance refunds only, rather than silently truncating fractional requests.
7. Sandbox seller balances can remain pending and block refunds, despite using test money. Whop's [sandbox guide](https://whop.com/blog/whop-sandbox/) describes asynchronous refund settlement and cancellation as a separate operation; the public deployment later reproduced a successful full refund.

## Not established yet

This is an alpha prototype, not production certification. Live-money processing, tax/FX refund reconciliation, authentication challenges, failed renewals, trial transitions, PostgreSQL concurrency, upgrade compatibility across the full supported Pay range and full accessibility checks remain unverified.
