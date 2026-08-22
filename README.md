# Agent-Mesh

Connect multiple **Hermes agents** into a knowledge network: they exchange
memories, skills, and insights, and share secrets through an encrypted vault —
"make each other smarter" for your fleet of machines.

```
┌─────────────────────────────────────────────┐
│  agent-mesh-memories (PRIVATE repo)         │
│  ┌──────────┬──────────┬──────────────────┐ │
│  │ agents/  │ agents/  │ vault/          │ │
│  │  ax41/   │  macbook/│  secrets.yaml   │ │
│  │  MEMORY  │  ...     │  (sops+age,     │ │
│  │  skills/ │          │   encrypted)    │ │
│  └──────────┴──────────┴──────────────────┘ │
└──────────────┬──────────────────────────────┘
               │ git pull / push (webhook-triggered)
     ┌─────────┴─────────┐
     │ Hermes Agent AX41 │    │ Hermes Agent Mac │
     └───────────────────┘    └──────────────────┘
```

- **Public repo** (`agent-mesh`): this framework — anyone can use it.
- **Private repo** (`agent-mesh-memories`): the data (memories/skills/vault).
  Memories are personal — never put them in the public repo.

## Prerequisites (per machine)

- Git + SSH key on GitHub (git@github.com)
- `age` and `sops` (vault)
- `hermes` (for knowledge export; without Hermes only git sync works)

```bash
# Debian/Ubuntu:
apt install age
curl -fsSL -o /tmp/sops.deb https://github.com/getsops/sops/releases/latest/download/sops_3.13.3_amd64.deb
dpkg -i /tmp/sops.deb
```

## Quickstart (one machine = one agent)

```bash
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/agent-mesh -o /usr/local/bin/agent-mesh
chmod +x /usr/local/bin/agent-mesh

agent-mesh init <agent-name>        # e.g. "ax41" or "macbook"
agent-mesh sync                     # export knowledge + push (webhook-triggered after that)
agent-mesh status                   # who is in the mesh?
```

## Vault (shared secrets)

Each agent has its own **age key** (`~/.hermes-mesh/keys/<name>.age`, chmod
600, never committed). Secrets are encrypted with the public keys of **all**
agents — everyone can read, nobody without a key.

```bash
agent-mesh vault set DB_PASSWORD "secret"   # store encrypted (all agents)
agent-mesh vault get DB_PASSWORD            # decrypt with own key
agent-mesh vault list                       # list key names
```

⚠ **Security:** The vault repo is private. Still: secrets belong only in the
vault, never in memory/insights.

## A2A — Agent-to-Agent communication

Messages flow as JSON files through the **private repo** (git queue pattern):
`messages/<recipient>/<id>.json`. The sender commits+pulls, the recipient
pulls on `agent-mesh sync` and reads with `agent-mesh inbox`. No open ports needed.

```bash
agent-mesh role hub|worker|specialist      # set own role (agent card)
agent-mesh send <agent> <text>             # send a message
agent-mesh reply <msg-id> <text>           # reply (auto-finds the original)
agent-mesh inbox                           # read own mailbox
agent-mesh route <agent> <text>            # hub only: route a message
agent-mesh agents                          # show all agent cards (roles)
```

**Roles:** `hub` = central point of contact (routes messages, knows
everyone), `worker` = executes tasks (default), `specialist` = domain expert.
Roles live in `agents/<name>/card.json` (in the private repo, visible to all).

### Real-time triggering (optional)

A webhook listener (`agent-mesh-webhook.py`, systemd service) makes sync run
**immediately** on every push — no waiting for the cron interval:

1. Run `agent-mesh-webhook.py` on `127.0.0.1:8765` (systemd unit included in the
   repo, secret in `mesh.conf`).
2. Expose it via a tunnel (e.g. Cloudflare) — HMAC signature verification
   (X-Hub-Signature-256) protects the endpoint.
3. Create a GitHub webhook on the **private** repo: `push` event →
   `https://mesh.<your-domain>/hook` with the secret.

## Insights (sharing learnings)

```bash
agent-mesh insight add "GH-8: preparation: is ignored, profiles_ch: is required"
```

→ lands as Markdown in `agents/<name>/insights/` and is visible to all mesh
agents (on next `agent-mesh sync`).

## Automation (cron fallback)

```bash
# daily 06:00: pull → export → push (webhook makes this optional)
echo "0 6 * * * root /usr/local/bin/agent-agent-mesh sync >> /var/log/mesh-sync.log 2>&1" \
  > /etc/cron.d/mesh-sync
```

## Onboarding new agents

See [docs/ONBOARDING.md](docs/ONBOARDING.md) (Linux/macOS) and
[docs/ONBOARDING-WINDOWS.md](docs/ONBOARDING-WINDOWS.md) (Windows: git-bash,
scoop, Task Scheduler).

## Privacy notice

- **Public**: framework code. No personal data.
- **Private**: memories/skills/insights/vault. Personal — never make it public.
- Hermes profile export redacts secrets automatically
  (`_EXPORT_REDACT_NAMES`); additionally `agent-mesh sync` filters agent-created
  skills only.
