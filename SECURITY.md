# Security reporting

Report suspected vulnerabilities privately through [GitHub private vulnerability reporting](https://github.com/yshmarov/pay-whop/security/advisories/new), or open this repository's **Security → Report a vulnerability** page. Avoid public issues for exploitable vulnerabilities.

Include the affected gem version, a minimal reproduction with synthetic data, expected/actual behavior, and the account or trust boundary involved. Do not include usable API keys, webhook secrets, buyer data, bank/card details or identity-verification documents. If a real credential was exposed, revoke or rotate it through the provider.

Testing and fixes target the latest alpha release. Reproduce on that release where possible; include the older version if that is where the issue was found. This community alpha has not undergone an independent security audit and is not a declaration of production readiness. See the [verification evidence and remaining limits](docs/verification.md).

Relevant boundaries include signed customer metadata, webhook authentication/replays, seller/account/environment isolation, exact money conversion, idempotent writes and confirmed provider state. Keep any proof of concept within accounts and systems you are authorized to test.
