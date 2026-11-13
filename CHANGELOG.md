# Changelog

## Unreleased

- Allow hosts to opt into multiple Pay customers for one Whop member with `Pay::Whop.allow_shared_members = true`. Each payment or membership must carry a valid signed customer reference when the member is ambiguous; an already linked customer cannot change its member or seller.
- Replace Pay's global processor/member uniqueness constraint with a non-Whop unique index and a Whop lookup index. Install the new migration before enabling shared buyers. Rolling it back requires first resolving duplicate Whop member mappings; it does not merge or delete records.
- Reconcile signed refund webhooks containing either `payment_id` or nested `payment.id`, as observed in a genuine sandbox refund. Reject conflicting references and re-read the canonical payment before applying the refund.

## 0.1.0.alpha.4

- Keep reversed payouts terminal when overlapping reads return an older completed state, for both platform and seller payouts.

## 0.1.0.alpha.3

- Retry existing failed membership payments and expose environment-validated 3DS recovery links.
- Add permitted renewal price reductions, billing period changes and next-renewal updates.
- Add fresh merchant readiness/capability checks, ledger balances, scoped payout status and reversal handling.
- Reconcile linked customer billing and merchant transfers/payouts; report unverifiable references without importing them.
- Normalize adapter API failures under `Pay::Error`, retain provider status/type and avoid automatic write retries.
- Deliver application webhook callbacks after synchronization; add payout and trial-ending events and reusable pending-delivery recovery.
- Expand CI across Pay 12.3/12.4 and SQLite/PostgreSQL; smoke-test installation from the packaged gem in a fresh Rails app.
- Extend the sandbox demo with failed-payment retry, reconciliation, recovery links and decline/3DS test instructions.

Provider limitations remain: invoice issuance and transfers are blocked by this sandbox's verification; bank payouts are unavailable in sandbox. Plan swaps, recurring quantity and metering remain unsupported.

## 0.1.0.alpha.2

Initial community adapter for one-time/recurring checkout, verified webhooks, saved methods, direct payments, refunds, invoices, disputes, entitlements and marketplace subaccounts. Public Rails playground with separate invoice/transfer simulations.
