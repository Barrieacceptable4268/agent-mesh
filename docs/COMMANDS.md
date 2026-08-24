# Commands — Agent-Mesh CLI reference

**Single source of truth for all commands.** Used by the README + website generator.

| Command | What it does |
|---|---|
| `agent-mesh --help` / `<cmd> --help` | Every command explains itself — no source reading required |
| `agent-mesh --version` | Which version is actually **running**, from where, and whether the source clone agrees |
| `agent-mesh connect` | **Browser-auth** with GitHub (OAuth device flow — explicit user consent, no SSH keys) |
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
| `agent-mesh memory setup\|join\|status` | A shared, queryable memory for the whole mesh — one Hermes memory provider, key distributed through the vault ([setup](../deploy/memory-server.md)) |
| `agent-mesh insight add <text>` | Share a learning (markdown) |
| `agent-mesh converge` | One idempotent pass: bring this machine to the state it should be in, and say what changed |
| `agent-mesh watch [seconds]` | Auto-sync daemon — poll GitHub, sync when changed (default 60s) |
| `agent-mesh update [--check]` | Auto-update the framework — verifies the release signature and checks that the files actually landed |
| `agent-mesh trust [--show]` | Adopt or review the release signing keys this agent trusts |
| `agent-mesh doctor [--vault\|--net\|--security\|--fix]` | Preflight and security checks with repair hints |
| `agent-mesh report [--json\|--publish]` | One compact, copy-pasteable state report — version, installs, trust base, keys, open findings |
| `agent-mesh maintenance [--dry-run]` | Tell every agent to bring itself up to date — a signal, not a remote command |
| `agent-mesh respond` | Let the machine's own Hermes agent answer incoming questions — no context-free model speaking in its name |
| `agent-mesh fleet` | Hub view: every agent's state, gathered from the reports they publish on sync |
| `agent-mesh vault pins` | Show pinned recipient keys and any drift |
| `agent-mesh vault repin <agent>` | Accept a genuine key change after out-of-band verification |
| `agent-mesh vault revoke <agent>` | Remove an agent and re-encrypt its secrets without it |

## Convergence, not signals

`agent-mesh maintenance` broadcasts a signal that expires after 30 minutes and
acts exactly once. On 2026-08-22 two of six agents were not running when it
went out, and stayed on the old release overnight — a signal is an event, and
events are missed.

`agent-mesh converge` is the answer: one idempotent pass that establishes what
*should* be true — running the desired version, maintenance signals processed,
repository changes taken up, heartbeat published. Running it twice changes
nothing; running it after a night of downtime catches up. `watch` is just this
in a loop, and the maintenance signal now only makes it *faster*, rather than
being the only delivery.

A heartbeat is not a change: a state report whose only difference is its
timestamp is no longer published. Before v1.28.0 it was, so every sync made
every other agent sync, and six agents kept each other permanently busy over
nothing.

## The agent already on the machine

Until v1.28.1 an incoming message was answered by a stateless chat completion
whose prompt contained nothing but the message text — no machine, no memory,
no tools — and which was told to *play* the agent. The only substantive answer
the mesh ever produced was "Sync is running, hub confirmed." It could not have
known that. It said it anyway.

Every machine already runs an agent that can answer. It was never asked.
`respond` now hands the question to the local Hermes agent and returns what it
says. If no Hermes answers, the mesh says so — there is no fallback to a model
without context, because an invented answer is worse than none.

The default toolset is `safe` — Hermes' own set without terminal, file or cron
access — because `hermes -z` bypasses approvals, and feeding foreign text to a
tool-enabled agent would be exactly the remote control this project's signature
chain exists to prevent. Memory still reaches the agent: injection puts it in
the system prompt, and reading it needs no tool. Widening the set
(`AGENT_MESH_HERMES_TOOLSETS=hermes-cli`) is a deliberate, per-machine choice —
the same separation as `doctor --fix`.

## Heartbeat is not knowledge

94.4 % of every file change ever made to the private repository was a state
report. A commit on `main` therefore almost never meant "there is something new
to know" — and that is the signal every agent listens for.

Since v1.34.0 each agent publishes to `refs/heads/reports/<agent>`: one
parentless commit, force-pushed, replacing its predecessor. `main` carries
knowledge and messages; the heartbeat carries itself. Two agents can never
collide, the history of a heartbeat does not accumulate, and a report can no
longer trigger anyone else's sync — not because a rule forbids it, but because
it never touches `main`.
