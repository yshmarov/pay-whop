# Verification

Verification date: 7 November 2026. Release: `0.1.0.alpha.2`.

## Versions and automated coverage

Ruby 4.0.9, Rails 8.1.4.1, Pay 12.4.0, Whop Ruby SDK 2.7.0, and Whop API date `2026-10-28-1`. The demo runs PostgreSQL and GoodJob on Render Free / Neon Free. Unit and integration tests use SQLite and WebMock at the SDK/HTTP boundary. No test credentials or captured customer payloads are committed.

The local suite passes **65 tests / 207 assertions** and Standard Ruby linting. GitHub Actions exercises Ruby 3.3, 3.4 and 4.0; see [CI runs](https://github.com/yshmarov/pay-whop/actions/workflows/ci.yml).

Coverage includes signed owner mapping, environment and seller isolation, conflicting identities, forged references, webhook authentication/replays/collisions, duplicate processing, pending-event recovery, enqueue refusal, stale snapshots, exact money conversion, full/partial refunds, asynchronous direct payments, saved methods, setup intents, invoice/dispute summaries, marketplace registration and transfers, terminal transfer-state protection, pause/access semantics, trial and past-due state mapping, and browser-session/CSRF/cross-customer boundaries.

## Actual sandbox evidence

The [hosted playground](https://pay-whop.onrender.com/) uses the adapter and receives actual signed Whop events. Its database persists across deployments and idle shutdowns. The app is sandbox-only; no live-money transactions were performed.

| Flow | Observed result |
| --- | --- |
| Hosted recurring checkout | Paid USD 24.00 including tax; one Pay charge and active subscription created by verified webhooks |
| Cancellation | Immediate and period-end cancellation, and reversal of scheduled cancellation, verified |
| Full refund | Provider reported USD 24.00 refunded; local Pay charge agreed |
| Saved payment methods | Retrieved a method through the linked member and selected the adapter's local default |
| Direct one-time saved-method payment | Initially `open`, later `paid`; USD 6.00 including tax, with no recurring subscription |
| Partial refund | Requested 100 minor units; provider and Pay reported exactly USD 1.00 refunded from the USD 6.00 payment |
| Pause / resume billing | Provider reported `paused_at`; adapter showed billing paused while retaining paid-period access; resume cleared the pause |
| Free days | Added one day and observed the changed provider period end |
| Draft invoice | Created and persisted a USD 5.00 draft |
| Invoice issue | Whop rejected issuance: account verification required. Draft remained unissued |
| Subaccount creation | Created a sandbox seller and verified its parent account before registering it locally |
| Hosted onboarding and payout links | Both generated valid sandbox Whop URLs after the required scopes were configured |
| Marketplace checkout | Created a USD 5.00 subaccount checkout configured with a USD 1.00 platform fee |
| Platform transfer | Whop rejected the request because the platform business is not verified; no transfer was recorded as successful |
| Visitor isolation | A separate hosted visitor could not see or cancel/refund another visitor's records; cross-customer actions returned 404 |
| Queue and deployment | PostgreSQL migrations, eager loading and persisted GoodJob execution verified; earlier deployment-time webhook failures recovered on Whop retry |

A generated checkout or payout URL is not proof of settled payment or bank withdrawal. Authentication challenges, dispute submission and evidence upload, authorization/capture/void, payment-method deletion, promo-code application, and full trial/failed-renewal lifecycles have HTTP-contract coverage only where exercised by tests, not complete real-provider coverage. Do not describe them as sandbox-certified.

## Integration findings

1. The sandbox Admin API-key role does not include `company:balance:read`, which account inspection needs. The expanded integration uses explicit custom scopes.
2. Hosted onboarding/payout links require additional financial scopes, including transfer/withdrawal exports and payout-destination operations. The API reports missing scopes explicitly.
3. Saved-payment-method listing accepts a member filter or an account filter, not both. The adapter lists through the linked member and never imports arbitrary supplied method IDs.
4. SDK 2.7 declares `partial_amount` as an integer even though the API accepts major-unit decimal amounts. Its JSON transport also ignores the documented `additional_body_parameters` option. Refunds therefore use a small authenticated HTTP fallback with exact decimal JSON numbers, a pinned API date, a stable idempotency key, TLS and bounded timeouts. Tests assert the outgoing fractional amount and no automatic write retry.
5. Payment capture returns a status object, not a complete Payment. The adapter retrieves the payment again before creating a Pay charge.
6. Under Rails, SDK objects must be converted via `to_h` before JSON serialization. Nullable SDK values can normalize to empty hashes; non-renewing memberships and unsettled transfer amounts are handled accordingly.
7. Whop's membership pause is reflected in `most_recent_action`, while the billing status can remain `active`. Pay access remains available through the current paid period.
8. Successful API responses may describe a pending operation. Neither a checkout return, an HTTP 200 nor a created transfer is treated as settlement.
9. Refunds and transfers can fail due to available balance or account capabilities, even in the sandbox. The adapter does not bypass identity verification.

## Remaining limits

This is an alpha integration, not a declaration of production readiness or full Pay/Stripe parity. Live-money processing, high-concurrency PostgreSQL races, full accessibility assessment, SCA recovery UX, FX/tax reconciliation, historical backfills, broad Pay-version upgrade compatibility and long-running renewal/retry behavior remain unverified.

Plan swaps/proration, recurring seat changes and metered billing are not implemented. The Whop `swaps` API is for currencies, not subscription plans. The adapter does not implement Whop's unrelated chat, ads, trading, cards or affiliate administration APIs; callers can use the official SDK for those.

The public playground intentionally has no seller administration or money-transfer controls. Marketplace buyers use a preconfigured sandbox seller. Invoice controls create drafts until the account can issue invoices. Secrets stay in private environment settings. The app's encrypted session lasts 30 days; reusing the same Whop buyer in an unrelated new session can trigger the adapter's deliberate identity-conflict protection.
