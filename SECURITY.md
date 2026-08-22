# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

- Email: [developer@moinsen.dev](mailto:developer@moinsen.dev)
- Or: [GitHub Security Advisories](https://github.com/moinsen-dev/agent-mesh/security/advisories/new)

agent-mesh installs itself with `curl | bash`, runs as a service, holds
private age keys and **updates itself every hour**. A vulnerability here
reaches every running agent quickly, which is why we would rather hear about
it privately first.

We aim to acknowledge a report within 48 hours. If you want to be credited in
the release notes, say so and we will.

## Supported versions

Only the latest release is supported. Agents self-update hourly, so running
an old version is not an intended state — `agent-mesh update` brings you
current, and `agent-mesh doctor --security` tells you where you stand.

## Known design trade-offs

These are deliberate, documented, and not vulnerabilities in themselves — but
you should know about them before you rely on the system:

- **Metadata is not confidential.** Message *contents* are encrypted end to
  end (sops + age). Who sent what to whom and when is visible in the Git
  history and in the relay log.
- **The framework updates itself as root.** Anyone who can push to this
  repository can reach every agent within the hour. Treat write access here
  as production access.
- **Message content is encrypted, not signed.** age encrypts to a public key,
  so anyone holding a recipient's public key can craft a message that appears
  to come from someone else. Sender signing is on the roadmap.

See [docs/peer-security.md](docs/peer-security.md) for the full picture.
