# Releasing

The current published alpha is [`0.1.0.alpha.5`](https://rubygems.org/gems/pay-whop/versions/0.1.0.alpha.5). Its [GitHub prerelease](https://github.com/yshmarov/pay-whop/releases/tag/v0.1.0.alpha.5) contains the matching gem artifact.

1. Update the version, lockfile, changelog and verification evidence together.
2. Run `bin/test`, the PostgreSQL suite, and `bundle exec ruby bin/install-smoke`. Confirm the GitHub CI matrix is green.
3. Build with `gem build pay-whop.gemspec --output pkg/pay-whop-0.1.0.alpha.5.gem` (create `pkg` first).
4. Inspect `gem specification pkg/pay-whop-0.1.0.alpha.5.gem files` and ensure no credentials, private fixtures or developer environment files are packaged.
5. A gem owner publishes with `gem push pkg/pay-whop-0.1.0.alpha.5.gem`. RubyGems MFA is required by the gem metadata. Configure credentials locally; never commit or paste an API key.
6. Create the matching GitHub prerelease with the built artifact and release notes. Register the deployed adapter's current webhook event list only after deploying the compatible code.

Do not label this production-ready while real invoice issuance, transfers and bank payouts lack provider validation. Keep sandbox-only demo simulations visibly separate from real adapter behavior.
