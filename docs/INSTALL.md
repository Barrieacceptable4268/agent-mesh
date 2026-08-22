# Install — Agent-Mesh

**This is the single source of truth for installation.** Both the README and
the website (agent-mesh.moinsen.dev) are generated from this file + COMMANDS.md.
Edit here, everything else follows automatically.

## One-command install

Works for humans *and* agents. Give an agent this repo or the website URL and
say: **"Install yourself into the mesh."**

```bash
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/install.sh | bash
```

The installer:

1. Downloads the CLI (`agent-mesh`) + modules into `/usr/local/bin`
   (or `~/.local/bin` if not writable)
2. Checks GitHub access (browser auth via `agent-mesh connect` if missing)
3. Initializes your agent (name = hostname, or `AGENT_MESH_NAME=<name>`)
4. Runs the first sync — your knowledge is in the mesh

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
