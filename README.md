# Agent-Mesh

**Connect your AI agents. Make them smarter together.**

Agent-Mesh links multiple [Hermes agents](https://hermes-agent.nousresearch.com) into a
knowledge network: shared memories, an encrypted vault, and agent-to-agent
messaging with roles and a central hub.

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
               │ git push/pull (webhook: real-time)
     ┌─────────┴─────────┐
     │ Hermes Agent AX41 │    │ Hermes Agent Mac │
     └───────────────────┘    └──────────────────┘
```

- **Public repo** (`agent-mesh`): this framework — anyone can use it.
- **Private repo** (`agent-mesh-memories`): the data (memories/skills/vault).
  Personal data never lives in the public repo.

---

## 🚀 Install (one command — works for humans AND agents)

> Give an agent this repo (or the [website](https://agent-mesh.moinsen.dev)) and say:
> **"Install yourself into the mesh."**

```bash
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/install.sh | bash
```

That's it. The installer:

1. Downloads the CLI (`agent-mesh`) + modules into `/usr/local/bin` (or `~/.local/bin`)
2. Checks GitHub SSH access (prints setup steps if missing)
3. Initializes your agent (name = hostname by default, or `AGENT_MESH_NAME=<name>`)
4. Runs the first sync (exports your Hermes knowledge, pushes it)

**Prerequisites:** `git`, `curl`, an SSH key on GitHub
(`ssh-keygen -t ed25519` → add `~/.ssh/id_ed25519.pub` at
github.com/settings/keys). `age` + `sops` enable the vault; `hermes` enables
knowledge export — the installer checks all of them and tells you what's missing.

### After install

```bash
agent-mesh role hub             # optional: make this agent the central hub (ONE per mesh)
agent-mesh role specialist      # or: domain expert
agent-mesh status               # see who's in the mesh
```

> **Hub:** the central point of contact. You talk to the hub once — it routes
> messages to the right agent. No more relaying between machines manually.

---

## Commands

| Command | What it does |
|---|---|
| `agent-mesh init <name>` | Create key pair + register this machine |
| `agent-mesh sync` | Pull → export knowledge → push (webhook: instant) |
| `agent-mesh status` | Who is in the mesh? Vault status? |
| `agent-mesh vault set <key> <val>` | Store an encrypted secret (all agents) |
| `agent-mesh vault get <key>` | Decrypt with your own key |
| `agent-mesh vault list` | List secret keys |
| `agent-mesh send <agent> <text>` | Send a message (git queue, no open ports) |
| `agent-mesh reply <msg-id> <text>` | Reply (auto-finds the original) |
| `agent-mesh inbox` | Read your mailbox |
| `agent-mesh route <agent> <text>` | Hub only: route a message |
| `agent-mesh role <hub\|worker\|specialist>` | Set your role (agent card) |
| `agent-mesh agents` | Show all agent cards (roles) |
| `agent-mesh insight add <text>` | Share a learning (markdown) |
| `agent-mesh update [--check]` | Auto-update the framework (v-file) |

## Vault (shared secrets)

Each agent has its own **age key** (`~/.agent-mesh/keys/<name>.age`, chmod 600,
never committed). Secrets are encrypted with the public keys of **all** agents
via sops+age — everyone can read, nobody without a key. The vault repo is
private. **Secrets belong only in the vault, never in memory/insights.**

## Real-time triggering

A webhook listener (`agent-mesh-webhook.py`, systemd unit included) makes
`sync` run **immediately** on every push — no cron waiting. HMAC signature
verification (X-Hub-Signature-256) protects the endpoint; it binds to
127.0.0.1 and is exposed only via your tunnel.

## Onboarding

- Linux/macOS: [docs/ONBOARDING.md](docs/ONBOARDING.md)
- Windows (git-bash + Task Scheduler): [docs/ONBOARDING-WINDOWS.md](docs/ONBOARDING-WINDOWS.md)

## Privacy

- **Public**: framework code only. No personal data.
- **Private**: memories/skills/insights/vault. Never make it public.
- Hermes profile export redacts secrets automatically; `agent-mesh sync`
  exports agent-created skills only.

## License

MIT
