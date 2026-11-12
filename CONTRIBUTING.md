# Contributing to pay-whop

Bug reports, documentation improvements and focused pull requests are welcome. This is a community alpha. Start with the [compatibility matrix](docs/compatibility.md) and [verification evidence](docs/verification.md) so proposed behavior matches Whop's API and the adapter's actual scope.

## Set up

Use Ruby 3.3 or newer:

```sh
git clone https://github.com/yshmarov/pay-whop.git
cd pay-whop
bundle install
bin/test
```

The suite runs against a real Rails application and Pay models. WebMock blocks external requests; API keys and a Whop account are not needed. `bin/test` runs tests and Standard Ruby linting. CI covers Ruby 3.3/3.4/4.0, Pay 12.3/12.4 and SQLite/PostgreSQL.

Optional checks:

```sh
# Use a dedicated PostgreSQL database ending in _test.
TEST_DATABASE_URL=postgresql://localhost/pay_whop_test bundle exec rake test

# Build/extract the gem, install migrations and boot a fresh Rails app.
bundle exec ruby bin/install-smoke
```

See the [demo guide](docs/demo.md) for sandbox credentials, local checkout and webhook setup. Keep credentials, captured buyer payloads and verification documents out of commits, issues, screenshots and fixtures.

## Make a useful change

- Explain the behavior or bug the change addresses. Include a small reproduction where possible.
- Add focused tests for money conversion, account/customer boundaries, idempotency, state transitions and failure recovery when those behaviors change.
- Keep external API calls outside database transactions. Re-fetch confirmed state after mutations rather than inferring settlement from an HTTP success.
- Preserve account/environment checks and signed customer mapping; do not match buyers by email.
- Use synthetic HTTP fixtures. Distinguish fixture coverage, actual sandbox observations and production validation in the description.
- Update the usage or compatibility guide if the public API or supported behavior changes.

Run `bin/test` before submitting. A passing suite does not prove that a provider operation works in every billing state; include the relevant API documentation and say which sandbox steps were actually performed.

## Report a bug or request a feature

Use the [issue forms](https://github.com/yshmarov/pay-whop/issues/new/choose). Include gem/Ruby/Rails/Pay versions, sandbox or production environment, a minimal reproduction and redacted errors/status codes. Do not post API keys, webhook secrets, private checkout links, card/bank data or buyer contact details.

For a vulnerability, use the private process in [SECURITY.md](SECURITY.md). For a feature request, describe the Rails/Pay use case and link to the relevant Whop API operation. Some Stripe concepts do not have a direct Whop equivalent.
