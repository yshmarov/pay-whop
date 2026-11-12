# Verification

Provider payment-flow verification: 7 November 2026. Expanded adapter, read-only sandbox operations and demo verification: 12 November 2026. Release: [`0.1.0.alpha.4` on RubyGems](https://rubygems.org/gems/pay-whop/versions/0.1.0.alpha.4). The registry SHA-256 matches the built gem tested by the installation smoke check.

## Versions and automated coverage

Ruby 4.0.9, Rails 8.1.4.1, Pay 12.4.0, Whop Ruby SDK 2.7.0, and Whop API date `2026-10-28-1`. The demo runs PostgreSQL and GoodJob on Render Free / Neon Free. Unit and integration tests use SQLite and PostgreSQL, with WebMock at the SDK/HTTP boundary. No test credentials or captured customer payloads are committed.

The local suite passes **100 tests / 369 assertions** and Standard Ruby linting. The local suite also passes with Pay 12.3.0; installation from the built gem into a fresh Rails application passes. GitHub Actions runs Ruby 3.3/3.4/4.0 × Pay 12.3.0/12.4.0 × SQLite/PostgreSQL; see [CI runs](https://github.com/yshmarov/pay-whop/actions/workflows/ci.yml).

Coverage includes signed owner mapping, environment and seller isolation, conflicting identities, forged references, webhook authentication/replays/collisions, duplicate processing, pending-event recovery, enqueue refusal, stale snapshots, exact money conversion, full/partial refunds, asynchronous direct payments, saved methods, setup intents, invoice/dispute summaries, marketplace registration and transfers, terminal transfer-state protection, pause/access semantics, trial and past-due state mapping, and browser-session/CSRF/cross-customer boundaries. Expanded tests cover existing-payment retries without duplicate charges, renewal restrictions, normalized API errors including lazy pagination/timeouts, application callback failure recovery, payout ownership/pagination/reversals, merchant capabilities, decimal balances and linked-customer reconciliation.

## Actual sandbox evidence

The [hosted playground](https://pay-whop.onrender.com/) uses the adapter and receives actual signed Whop events. Its database persists across deployments and idle shutdowns. The app is sandbox-only; no live-money transactions were performed.

| Flow | Observed result |
| --- | --- |
| Hosted recurring checkout | Paid USD 24.00 including tax; one Pay charge and active subscription created by verified webhooks |
| Cancellation | Immediate and period-end cancellation, and reversal of scheduled cancellation, verified |
| Full refund | Provider reported USD 24.00 refunded; local Pay charge agreed |
| Saved payment methods | Retrieved a method through the linked member and selected the adapter's local default |
| Hosted setup checkout | Saved the test method without a charge; signed `setup_intent.succeeded` delivery processed |
| Hosted one-time checkout | Paid USD 6.00 including tax; signed webhook created a charge without a recurring subscription |
| Authorization / capture / void | Two payments became `authorized`; capture became `paid` with a Pay charge, void became `void` without a Pay charge |
| Direct one-time saved-method payment | Initially `open`, later `paid`; USD 6.00 including tax, with no recurring subscription |
| Partial refund | Requested 100 minor units; provider and Pay reported exactly USD 1.00 refunded from the USD 6.00 payment |
| Pause / resume billing | Provider reported `paused_at`; adapter showed billing paused while retaining paid-period access; resume cleared the pause |
| Free days | Added one day and observed the changed provider period end |
| Draft invoice | Created and persisted a USD 5.00 draft; generated an HTTPS invoice PDF URL |
| Invoice issue | Whop rejected issuance: account verification required. Draft remained unissued |
| Subaccount creation | Created a sandbox seller and verified its parent account before registering it locally |
| Hosted onboarding and payout links | Both generated valid sandbox Whop URLs after the required scopes were configured |
| Marketplace checkout | Completed a USD 5.00 subaccount checkout; provider reported USD 6.00 including tax. The fee report confirmed a collected USD 1.00 application fee; the signed child event created a charge under the seller-scoped customer |
| Platform transfer | Whop rejected the request because the platform business is not verified; no transfer was recorded as successful |
| Merchant readiness / balances (12 Nov) | Fresh account capabilities and USD ledger balances retrieved; card payments active, transfer and payout capabilities inactive |
| Merchant reconciliation (12 Nov) | Authenticated transfer/payout lists returned successfully with zero records; this does not prove settlement |
| Linked customer reconciliation (12 Nov) | One membership and one payment recovered; seven references from a different application signing context were skipped and reported |
| Visitor isolation | A separate hosted visitor could not see or cancel/refund another visitor's records; cross-customer actions returned 404 |
| Queue and deployment | PostgreSQL migrations, eager loading and persisted GoodJob execution verified; earlier deployment-time webhook failures recovered on Whop retry |

A generated checkout or payout URL is not proof of settled payment or bank withdrawal. Completed provider authentication challenges, dispute submission and evidence upload, one-time entitlement reactivation, payment-method deletion, promo-code application, and full trial/failed-renewal lifecycles have HTTP-contract coverage only where exercised by tests, not complete real-provider coverage. Do not describe them as sandbox-certified.

The deployed webhook subscribes to all 30 adapter events, including payout changes and trial-ending notifications, with subaccount events enabled. No pending deliveries remained after the checkout and setup tests. The earlier provider-flow review covered desktop layout; a full mobile/accessibility assessment remains outstanding.

## Integration findings

1. The sandbox Admin API-key role does not include `company:balance:read`, which account inspection needs. The expanded integration uses explicit custom scopes.
2. Hosted onboarding/payout links require additional financial scopes, including transfer/withdrawal exports and payout-destination operations. The API reports missing scopes explicitly.
3. Saved-payment-method listing accepts a member filter or an account filter, not both. The adapter lists through the linked member and never imports arbitrary supplied method IDs.
4. SDK 2.7 declares `partial_amount` as an integer even though the API accepts major-unit decimal amounts. Its JSON transport also ignores the documented `additional_body_parameters` option. Refunds therefore use a small authenticated HTTP fallback with exact decimal JSON numbers, a pinned API date, a stable idempotency key, TLS and bounded timeouts. Tests assert the outgoing fractional amount and no automatic write retry.
5. Payment capture returns a status object, not a complete Payment. The adapter retrieves the payment again before creating a Pay charge.
6. Under Rails, SDK objects must be converted via `to_h` before JSON serialization. Nullable SDK values can normalize to empty hashes; non-renewing memberships and unsettled transfer amounts are handled accordingly.
7. Whop's membership pause is reflected in `most_recent_action`, while the billing status can remain `active`. Pay access remains available through the current paid period.
8. Successful API responses may describe a pending operation. Neither a checkout return, an HTTP 200 nor a created transfer is treated as settlement.
9. Immediate cancellation can leave `cancel_at_period_end: true` on the provider object. Terminal status and `canceled_at` take precedence so ended subscriptions cannot retain access or appear resumable.
10. Refunds and transfers can fail due to available balance or account capabilities, even in the sandbox. The adapter does not bypass identity verification.

## Remaining limits

This is an alpha integration, not a declaration of production readiness or full Pay/Stripe parity. Live-money processing, high-concurrency PostgreSQL races, full accessibility assessment, completed provider SCA recovery, FX/tax reconciliation, global historical imports, compatibility beyond the tested matrix and long-running renewal/retry behavior remain unverified. Renewal price/cadence/date mutations and bank payout transitions have HTTP-contract coverage; they were not validated by running a complete real provider billing cycle. Local browser checks confirmed the recovery URL/error state and new demo controls at desktop, 320px and 390px widths; the preview used blocked-network HTTP fixtures, not a completed Whop challenge.

Plan swaps/proration, recurring seat changes and metered billing are not implemented. The Whop `swaps` API is for currencies, not subscription plans. The adapter does not implement Whop's unrelated chat, ads, trading, cards or affiliate administration APIs; callers can use the official SDK for those.

The public playground intentionally has no seller administration or money-transfer controls. Marketplace buyers use a preconfigured sandbox seller. Invoice controls create drafts until the account can issue invoices. Secrets stay in private environment settings. The app's encrypted session lasts 30 days; reusing the same Whop buyer in an unrelated new session can trigger the adapter's deliberate identity-conflict protection.

## Demo-only simulations

The public playground has a separate, amber-labelled simulation section. Invoice flows cover draft → issued → paid, past due → paid, and void outcomes. Transfer flows cover pending → succeeded/failed. Each can be reset. State and activity persist for the visitor's own demo session; another session cannot read or advance those records.

These controls only write separate demo records. They make no Whop API calls, create no provider resources, enqueue no provider webhook deliveries, create no Pay charges or subscriptions and move no funds. A simulated outcome is not proof of API compatibility, business verification, actual invoice payment or settled transfer. The gem's real invoice and transfer methods keep their provider checks and errors. The simulator is available before linking a Whop buyer, and mutation requests reject a production Whop environment.

Automated coverage checks lifecycle transitions, repeated starts, reset, terminal outcomes, session isolation, CSRF, the sandbox guard and absence of Pay billing records or external requests. Local browser checks exercised invoice issuance/overdue/payment and transfer failure before deployment. The simulation section was inspected at 320px and 390px viewport widths with no page overflow; this is not a full accessibility assessment.

The fresh-install smoke check builds and extracts the actual gem, generates a separate Rails application, installs Pay and adapter migrations in separate commands, migrates the database, eager-loads, creates a Whop customer and verifies the webhook route and recovery job. It uses no API credentials or external payment calls.
