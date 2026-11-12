# Expanded alpha ready for developers

**Outcome:** Move the integration toward a usable community release while keeping provider validation distinct from automated coverage.

- **Whop's model sets the scope.** Implement permitted renewal changes and existing-payment recovery, without promising Stripe plan swaps, proration or usage billing that the provider does not expose in the same way.
- **Keep moving around verification.** Preserve real invoice/transfer methods and their errors; clearly labelled demo simulations remain separate. Real-money validation is deferred until provider capability access and a specific test budget are available.
- **Reconcile ownership carefully.** The same sandbox account/member can contain checkouts from different application signing contexts. Report unverifiable references and skip them; never guess an owner from email.
- **Payout readiness is capability-specific.** Card acceptance does not prove transfers or bank payouts are available. Hosted payout initiation remains with Whop; this release adds reads and reconciliation.
- **Publish an alpha.** Package a reusable gem and document installation and recovery; do not claim full Stripe parity or production readiness from HTTP fixtures.
- **User handles new publishing credentials.** Existing RubyGems CLI credentials were subsequently found in Ruby 4's configuration location, so no additional API key was needed.

**Next step:** Complete real invoice issuance and transfer validation when Whop provides supported sandbox verification; bank settlement needs a supported environment because Whop documents payouts as unavailable in sandbox.
