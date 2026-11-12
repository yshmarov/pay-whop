# Run the sandbox playground

From the repository root, using Ruby 3.3 or newer:

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

## Screenshots

Repository screenshots were captured from the deployed sandbox on 12 November 2026. Billing screenshots show synthetic customers and Whop test payments; they contain no API keys, buyer contact details or live-money transactions. Tax can make a USD 5.00 checkout appear as USD 6.00 in the billing table. The amber invoice/transfer section uses separate local simulation records.
