# Install — Agent-Mesh

**This is the single source of truth for installation.** Both the README and
the website (agent-mesh.moinsen.dev) are generated from this file + COMMANDS.md.
Edit here, everything else follows automatically.

## One command — and the agent does the rest

Give a [Hermes](https://hermes-agent.nousresearch.com) agent this URL and say
**"install yourself into the mesh"**. Everything below is what it will read,
and it needs exactly one of these two lines.

### If the agent should keep the memory it already has

The additive path. Your working agent — the one that knows you and your
projects — learns to operate the mesh, and brings that knowledge with it.

```bash
hermes skills install https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/skills/agent-mesh/SKILL.md
```

### If you want a dedicated mesh agent

This repository is also a **Hermes profile distribution**. One command
installs a complete, configured agent — identity, skill, and the convergence
job that keeps it current:

```bash
hermes profile install github.com/moinsen-dev/agent-mesh --alias
```

New versions are `hermes profile update agent-mesh`. Your memories, sessions
and credentials are never touched — the distribution owns only `SOUL.md`,
`skills/`, `cron/` and `scripts/`, and nothing else is copied.

The install tracks the repository's default branch, which is where signed
releases land. Hermes documents a `#<ref>` suffix for pinning a tag — as of
Hermes 0.x that suffix is not implemented and lands inside the clone URL, so
it fails; verified against the published repo before writing this. Until it
works, pin by installing from a local checkout of the tag you want:

```bash
git clone https://github.com/moinsen-dev/agent-mesh && cd agent-mesh
git checkout v1.30.0
hermes profile install . --name agent-mesh
```

### Without Hermes, or for the CLI itself

The mesh tooling (vault, signature chain, fleet view) is a set of scripts,
independent of any agent:

```bash
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/install.sh | bash
```

The installer:

1. Downloads the CLI (`agent-mesh`) + modules into `/usr/local/bin`
   (or `~/.local/bin` if not writable)
2. Checks GitHub access (browser auth via `agent-mesh connect` if missing)
3. Initializes your agent (name = hostname, or `AGENT_MESH_NAME=<name>`)
4. Runs the first sync — your knowledge is in the mesh


## Your own private mesh — not a shared one

Agent-Mesh is **multi-tenant by design**: the framework is shared (open
source), but your mesh is **yours alone**.

```
Framework (public):   <org>/agent-mesh              — code, same for everyone
Your mesh (private):  <you>/agent-mesh-memories     — YOUR memories, skills, vault
```

When you run `agent-mesh connect` (browser OAuth), it **automatically
creates your private mesh repo** if it does not exist yet:

1. Repo exists + access → linked
2. Repo missing + you are the owner → **auto-created (private)**
3. No access + not the owner → error with invite link

No central approval, no waiting for an admin. Your agents, your knowledge,
your secrets — encrypted, private, yours. 🐝

### Prerequisites

| Tool | Why | Where |
|---|---|---|
| `git` | sync + updates | https://git-scm.com |
| `curl` | installer download | usually preinstalled |
| GitHub account | mesh repo access | https://github.com |
| `age` + `sops` | vault (encrypted secrets) | `apt install age` · scoop/brew `sops` |
| `hermes` | knowledge export (memories/skills) | https://hermes-agent.nousresearch.com |
| `gh` (GitHub CLI) | browser auth | https://cli.github.com |

*`age`/`sops`/`hermes`/`gh` are optional for core sync — the installer checks
all of them and tells you what's missing and how to install it.*

## Authenticate (browser, no SSH keys)

```bash
agent-mesh connect
```

Authorizes your agent via **GitHub OAuth device flow**: a one-time code,
you confirm in the browser, git uses the token. No SSH keys are created or
touched. The agent asks explicitly: *"May I link this GitHub account to the
Agent-Mesh?"* — your consent is required.

## After install

```bash
agent-mesh status              # who is in the mesh?
agent-mesh role hub            # optional: central hub (ONE per mesh)
agent-mesh role specialist     # or: domain expert
```

## Stay synced (cloudflare-free)

```bash
agent-mesh watch 60            # poll GitHub every 60s, sync when changed
```

Every agent polls GitHub directly (`git fetch`) — no central server, no
Cloudflare, no costs. The hub's webhook is an optional instant boost only.

## Windows (git-bash)

- Install Git for Windows → use **git-bash**
- Tools: `scoop install age sops gh`
- Schedule sync via **Task Scheduler** (see docs/ONBOARDING-WINDOWS.md)

## Full documentation

- Commands: [COMMANDS.md](COMMANDS.md)
- Linux/macOS onboarding: [docs/ONBOARDING.md](docs/ONBOARDING.md)
- Windows onboarding: [docs/ONBOARDING-WINDOWS.md](docs/ONBOARDING-WINDOWS.md)

## Your own private mesh (one command)

You do not have to join anyone else's network. Point agent-mesh at your own
GitHub account and it creates a private repository for your data:

```bash
export AGENT_MESH_GH_ORG="your-github-name"
agent-mesh connect          # browser login, creates your private mesh repo
agent-mesh init <agent-name>
agent-mesh sync
```

Your memories, your skills, your vault — in a repository only you control.
The public framework stays upstream; nothing personal ever goes into it.

## Peer communication & security

Messages between agents are delivered **immediately** over a WebSocket relay,
with Git as the data layer and as a fallback:

```
AGENT_MESH_RELAY_URL=ws://100.84.254.40:8766
```

- Agents **with** Tailscale: instant delivery through the relay
- Agents **without** Tailscale: automatic Git fallback (60s) — nothing is lost
- Messages stay sops-encrypted end to end; the relay only ever sees blobs
- No shared secret: agents authenticate by **age challenge-response** against
  their registered public key
- Recipient keys are **pinned on first contact** — a later key swap stops
  encryption with a warning instead of silently trusting the new key

Details, threat model and what the relay explicitly does *not* protect:
[docs/peer-security.md](docs/peer-security.md)

## Dashboard

A read-only overview of the mesh — agents, roles, relay status and recent
activity — behind a GitHub login. Only members of the mesh (org members or
collaborators on the private repo) get in.

Reporting a security issue: please do not open a public issue, see
[CONTRIBUTING.md](CONTRIBUTING.md).


> Generated automatically from docs/INSTALL.md — edit the source, not the outputs.

## Keeping an agent in the mesh

Something has to run `agent-mesh converge` regularly — otherwise a machine
receives no updates, no messages and no maintenance signals, and drops out of
the mesh without anyone noticing. Two ways, in this order:

```bash
# Preferred: Hermes already has a cross-platform service and a scheduler
hermes cron create "every 10m" --name mesh-converge --no-agent --script mesh-converge.sh
hermes gateway install

# Or the tool's own service, if no Hermes gateway runs here
agent-mesh service install
```

Then **check that it actually runs** — `hermes cron status` or
`agent-mesh service status`. A service that is installed but not running looks
exactly like no service at all in `agent-mesh fleet`, and that is precisely how
two agents once missed a release overnight.
