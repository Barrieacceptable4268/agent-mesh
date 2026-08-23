# Migrations

What to do when moving to a new version. `agent-mesh update` automatically
shows every agent the sections between its old and the new version — nobody
has to think of reading this file.

Format: one `## vX.Y.Z` heading per version, plain text below it.

## v1.28.1

Nothing to do. Umlauts restored in the `fleet` and `doctor` output that
v1.28.0 printed as `laeuft` / `gruen`.

## v1.28.0

**Nothing to do by hand.** Every change below takes effect on its own after
the update.

**A signal is an event, and events get missed.** On 2026-08-22 a maintenance
broadcast reached four of six agents. The other two were not running at that
moment, and the signal — valid for 30 minutes, acting exactly once — was gone
for good. They sat on the old release all night, and the fleet table
summarised it as "0 reports older than 24h".

`agent-mesh converge` replaces the event with a state. One idempotent pass
brings this machine to where it should be: desired version installed,
maintenance signals processed, repository changes taken up, heartbeat
published. Twice changes nothing; after a night of downtime it catches up on
the first run. `watch` is now that pass in a loop, and the maintenance signal
only makes it faster.

Three things follow from that, and they are the reason this is a release of
its own:

  * **`watch` checks for a new version immediately on start**, not after 60
    cycles. A cycle counter restarts at zero with the process, so a restarted
    watcher used to be blind for an hour — exactly when it is most likely to
    be behind.
  * **A heartbeat is not a change.** A report whose only difference is its
    timestamp is no longer published. Before, every sync gave every other
    agent something to sync, and six agents kept each other permanently busy
    over nothing. Every agent still refreshes its report at least hourly
    (`AGENT_MESH_HEARTBEAT`), so silence stays meaningful.
  * **Silence is now a finding.** `fleet` marks any agent without a sign of
    life for more than two hours and names it; `doctor` reports a missing
    watch process instead of merely recording it. An agent nobody hears from
    receives no updates, no messages and no maintenance signals — and used to
    look green while doing so.

**The command line explains itself.** `agent-mesh --help`, `agent-mesh
--version` and `agent-mesh <command> --help` exist, work without a
configuration, and cover every command including its flags. An unknown
command suggests the nearest match instead of printing 24 names. Nothing was
renamed, no flag changed meaning; every previous invocation keeps working.

**And there is a test suite** — `tests/run.sh`, no dependencies, part of CI.
It also holds together things that used to drift apart in silence: the
embedded version against `VERSION`, the help against the dispatcher, and the
download list in `install.sh` against the modules that actually exist.

## v1.27.0

**`agent-mesh doctor --fix`, and findings that name the file.**

The first fleet-wide broadcast left three findings, and two of them were
things an agent can safely repair on its own: private key files at 644, and a
dead `AGENT_MESH_RELAY_TOKEN` line in the config. Those now fix themselves.

`--fix` does **only** what provably cannot break anything: tighten permissions
on your own keys, and remove a config line that has no function (with a
`.bak`). Anything needing judgement — a key change, overwriting an
installation, restarting a service — is deliberately left alone and merely
named. That separation is why `--fix` is also safe to run from a maintenance
broadcast, which it now does.

The third finding exposed a gap in the report itself: "1 Datei(en) weichen ab"
does not tell you which one. It now names them:

```
❌ /usr/local/bin — 2 Datei(en) weichen ab: agent-mesh-relay.py agent-mesh-dashboard.js
```

That is the difference between a finding and a task.

## v1.26.0

**`agent-mesh maintenance` — one command, the whole fleet updates itself.**

```bash
agent-mesh maintenance --dry-run   # who would be told
agent-mesh maintenance             # tell them
agent-mesh fleet                   # watch it happen
```

Every agent picks the signal up on its next watch cycle (≤60s), runs update →
trust → sync, and reports back. No more pasting the same three commands into
six terminals.

### The design rule this follows

The message is a **signal, not a command**. The only thing transmitted is the
word `self-update`; *what* that does is fixed in the receiving agent's own
code and cannot be influenced by the sender. A channel that carried arbitrary
commands would be precisely the remote control this project spends its
signature machinery preventing.

Three independent barriers, each sufficient on its own:

1. the message must pass signature verification (finding 10)
2. the sender must be listed in `MAINTENANCE_FROM` — default: whoever holds
   the `hub` role
3. it must be under 30 minutes old, and it acts exactly once

All four refusal cases were tested: an unauthorised sender, a forged message
encrypted to the recipient's public key, a genuine signal two hours old, and
the same signal replayed.

And if all three barriers failed, the triggered sequence still installs only
releases with a valid signature (finding 8). The worst reachable outcome is
that every agent becomes current.

### One thing it deliberately does not do

`trust` runs only when no trust base exists yet. A **change** of signing key
stays a human decision — otherwise the trust base itself would be replaceable
by broadcast, and the whole signature chain would be worth nothing.

### Restricting it further

```bash
echo "MAINTENANCE_FROM=ax41" >> ~/.agent-mesh/agent-mesh.conf
```

## v1.25.0

**A broken fleet report now says why, and a broken one is never published.**

The first production `agent-mesh fleet` showed one agent as `defekt` with no
further explanation — which is the same failure this tool was built to end:
a statement you cannot act on. Two changes:

- `fleet` now prints the file size, the parser error and the first 60
  characters of an unreadable report. "41 B, JSONDecodeError: ℹ️ irgendeine
  Meldung" identifies the cause in one line.
- `sync` writes the report to a temporary file, validates that it parses, and
  only then publishes it. A half-written or polluted report made a healthy
  agent look broken in the overview; now the agent says so locally instead and
  keeps its last good report.

If an agent shows as `defekt`, look at it directly:

```bash
agent-mesh report --json | head -5
```

Anything before the opening `{` is the cause.

## v1.24.0

**Fleet overview: `agent-mesh fleet`.**

Every agent now publishes its own state report to `agents/<name>/report.json`
on each `sync`, and the hub reads all of them at once:

```
AGENT                    VERSION   BERICHT  TRUST  KEYS   RELEASE    SEC     PROBLEME
ax41                     1.24.0    12m      ja     ok     signiert   ok
nucbox-evo-x2            1.12.1!   2d!      NEIN   FEHLT  kein Tag   3 offen  Keine Vertrauensbasis
6 Agent(en) · 2 nicht auf v1.24.0 · 1 Bericht(e) älter als 24h · 4 mit offenen Punkten
```

Git carries it, so there is no new port, no service, and no agent that has to
be online at the moment you ask. The report is a normal commit, which means
the history of the fleet comes along for free.

The `BERICHT` column is the one to read first: a report from two days ago
describes a two-day-old state. A stale entry is marked, because the failure
mode this whole tool exists to prevent is believing an outdated statement.

Nothing to configure — the report appears with the next `sync`.

## v1.23.0

**The dashboard now says why an OAuth login failed, and which version is
running.**

`OAuth-Token-Austausch fehlgeschlagen` covered three unrelated causes: a
deployed dashboard still missing the `await` fix, wrong client credentials, or
a redirect URI that does not match the OAuth app. The message named none of
them, so every occurrence sent the operator down a guess.

It now reports GitHub's actual error, adds a targeted hint, logs it
server-side, and prints the running version. New unauthenticated endpoint:

```bash
curl -s https://mesh-console.moinsen.dev/healthz
# {"status":"ok","version":"1.23.0"}
```

That answers, from outside and in one second, the question that kept coming up
today: is the service running the version we think it is?

**On the hub, before updating**, this tells you whether the old dashboard is
the cause of a failing login:

```bash
grep -c "await awaitFetch" /usr/local/bin/agent-mesh-dashboard.js
# 0 = pre-v1.13 file, the login cannot work at all
```

## v1.22.0

**A pipeline bug that inverted conditions, plus two installer fixes.**

`cmd | grep -q pattern` inside a script with `set -o pipefail` is wrong, and
wrong in the worst way: `grep -q` closes the pipe on the first match, the
writer takes SIGPIPE, and pipefail turns that into a failed pipeline. The
condition therefore becomes false **precisely when there is a match**. It only
shows up once the output exceeds the pipe buffer (~64 KB), so it passes every
small test and fails in production. `ps ax` on a normal machine is enough.

It was making `agent-mesh report` claim "watcher nicht aktiv" while the
watcher was running. Eight more occurrences were found and fixed across the
tree — the LLM-reply check in autofix, the launchd lookup, the tag lookup, the
responder question detection, and the SSH check in install.sh. The CI gate now
rejects the pattern.

Two installer fixes:

- Agent names got a trailing hyphen, because `tr -c` converts the newline too
  (`macbookpro-m4-fritz-box-`). Existing names are untouched; rename by
  editing `AGENT_NAME` in your conf and running `agent-mesh sync`.
- `install.sh` downloaded a stale file list: `dashboard.js`, `autofix.sh` and
  `govern.sh` were missing, so freshly installed agents lacked modules that
  updated agents had.

## v1.21.0

**New: `agent-mesh report`.**

One command, one copy-pasteable block: version and commit of the framework
clone, whether the remote is ahead, every installation location and whether
its files match, which `agent-mesh` actually wins on PATH, the trust base, the
release-tag signature, key state, and the open security findings — nothing
else from the doctor, just what is wrong.

It exists because the first fleet rollout produced four prose reports and
several of them described a state that was not there. Not carelessness: the
tools reported what they *did*, not what came of it. This one reports only
observations from the filesystem and from git, and it deliberately runs on a
machine where nothing is set up — that is when it is worth the most.

Use it instead of asking an agent how the rollout went:

```bash
agent-mesh report
```

## v1.20.0

**`update` now checks the result, not just the action.**

Three times during the rollout a tool reported success while nothing arrived:
`.js` files were never copied, a second installation shadowed the fresh one,
and a service kept pointing at the old path. The common thread was never a
wrong copy command — it was that nobody looked afterwards.

After installing, `update` now compares every file it wrote against the
framework clone and reports any that did not land. It also checks whether the
`agent-mesh` first on your PATH is the one it just wrote; if an older
installation shadows it, that is now a loud warning instead of a silent
mismatch between "update succeeded" and "the old code is still running".

Nothing to do. The next update tells you if it worked.

## v1.19.3

`doctor --security` claimed releases were unsigned when they were not.

It looked for the release tag in the local framework clone without fetching
it first — and `git pull origin main` does not reliably bring tags along. So
on a clone that simply had not seen the tag yet, the doctor announced "this
release was not tagged" and pointed at the maintainer. Two agents drew exactly
that conclusion and reported it as a maintainer to-do.

The check now fetches the tag first, and distinguishes the two cases it was
conflating: a tag that exists on the remote but not locally (fetch it) versus
a release that genuinely was never tagged (a maintainer task). Found by the
hermes-hetzner agent.

## v1.19.2

`doctor --security` reported wrong key permissions on Linux. Found by the
ax41 agent during the rollout.

BSD and GNU `stat` are not interchangeable, and the `||` fallback did not
save it: GNU `stat -f` does exit non-zero, but it writes file-system
information to stdout first, and the command substitution collected both. The
value being compared was multi-line noise ending in the real mode, so correct
permissions were reported as wrong. Now decided by platform instead of tried.

The same trap sat in `agent-mesh autofix`, where `stat -c %U` silently
returned nothing on macOS and always pushed it down the sudo path.

Nothing to do — run `doctor --security` again and the false finding is gone.

## v1.19.1

`doctor --security` gained two things that came out of the first real rollout.

**It no longer stops halfway.** On an agent that had not published a signing
key yet, an `ls` over an empty glob failed and `set -e` tore down the rest of
the report — precisely on the agents that needed it most.

**It now reports parallel installations.** If `/usr/local/bin` is not
writable — on macOS as a normal user, the usual case — the updater installs to
`~/.local/bin` and any older copy in `/usr/local/bin` simply stays. A service
pointing there keeps running the old code while `update` reports success. The
doctor now lists every install location, marks the ones that differ from the
framework clone, and says which one is actually on your PATH.

Nothing to do beyond running `agent-mesh doctor --security` again.

## v1.19.0

**Preparation for the v2 source layout — nothing to do, but it has to land
before the files move.**

`install_framework` searched only the repository root. Once sources move into
`bin/`, `lib/` and `web/`, an old copy loop would find nothing there — and
since an update always runs the *previous* version's loop, the fleet would
stop at the release before the move. Exactly the trap that already caught
`.js` files once.

So this release makes the search recursive while **nothing has moved yet**.
Every agent has to be on v1.19.0 or later before the restructure ships.

The *installed* layout stays flat: the main script finds its modules next to
itself via `dirname "$0"`, and that stays true. Only the repository gets
structured.

Verified: the current flat tree and a simulated `bin/ lib/ web/ share/` tree
produce an identical list of 14 installed files, `.github/scripts/check.sh`
and a stray `.sh` under `docs/` are correctly ignored, the result runs and
resolves its modules, and two files sharing a basename are reported instead
of silently overwriting each other.

Also fixed here: the v1.13.0 instructions told you to copy
`agent-mesh-relay.service` from `/usr/local/bin`, where it never was —
`.service` files are not installed by the updater. It now points at the
framework clone.

## v1.18.1

Fixes a dashboard bug the new CI gate found on its first run: the relay status
check used `{ timeout: 3 }` — three **milliseconds**. It always timed out, so
the dashboard reported the relay as offline no matter what it was doing. Now
3000. Nothing to do beyond deploying the dashboard file.

## v1.18.0

**Configuration can live in the conf file now — nothing to do.**

`GH_ORG`, `PUBLIC_REPO`, `PRIVATE_REPO` and `PYTHON_BIN` were environment
variables only, so anyone running their own mesh had to export them in every
shell. They can now sit in `~/.agent-mesh/agent-mesh.conf`, and
`agent-mesh init` writes them there when they differ from the defaults.

Priority is environment variable > conf file > default, so nothing you set
today changes behaviour. An existing conf without those keys keeps working
exactly as before.

Idea and first implementation: [@HearthCore](https://github.com/HearthCore) in
PR #8.

## v1.17.0

**Metadata cleanup — nothing to do.**

Message contents were always encrypted, but the surroundings gave a lot away.
Closed now:

- Commit messages say `msg: verschlüsselt` instead of `msg: ax41 → macmini`.
  Note that the Git history keeps the old ones — this only stops new leakage.
- The relay logs counters instead of sender/recipient pairs and byte counts.
  `--log-level DEBUG` (or `AGENT_MESH_LOG_LEVEL=DEBUG`) restores the detail
  while you are chasing a fault.
- Blobs are padded to 2 KB blocks, so the file size no longer reveals whether
  someone wrote "ja" or three paragraphs.

Deliberately **not** hidden: the mailbox layout and the envelope beside each
blob still name sender, recipient and time. Delivery needs the first and
troubleshooting needs the second, and anyone who can read them already has
access to the private repository. `SECURITY.md` states this plainly rather
than implying more protection than exists.

## v1.16.1

Fixes a dead end found while rehearsing the rollout: an agent whose framework
clone predates the signing change had no way forward. `agent-mesh trust`
needs `.github/allowed_signers` from the clone, and `agent-mesh update`
refuses to advance the clone without a trust base — so the agent sat there.
`trust` now falls back to fetching the file from `origin/main`, which is
harmless: it is a proposal you confirm anyway.

Nothing to do. If an agent is stuck reporting "Keine vertrauten
Signaturschluessel hinterlegt" and `trust` cannot find the file, this
release is the fix — reinstall it once with:

```bash
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/install.sh | bash
```

## v1.16.0

**Hardening only — nothing to do by hand.**

- The relay now enforces limits that were missing: at most 5 connections per
  agent and 20 per IP, 30 messages per minute per agent, and a frame cap of
  256 KB instead of 2 MB. Agents that stay within normal use will not notice;
  a runaway loop or a hostile client hits a wall instead of the hub's memory.
- The webhook handles requests in threads (one slow connection no longer
  blocks every other), rejects bodies over 1 MB **before** checking the
  signature, and answers 500 instead of dying when `agent-mesh` is missing.
- The systemd unit is written straight to `/etc/systemd/system` instead of
  being staged through `/tmp` — a local user could previously swap the file
  between writing and copying and have root install their unit.

If a client of yours legitimately needs to exceed those relay limits, the
constants sit at the top of `agent-mesh-relay.py`. Raising them is a decision,
not a workaround — say why in the commit.

## v1.15.0

**Messages are now signed. Nothing to configure — but the first sync of every
agent matters.**

### What changed

Encryption proves confidentiality, never authorship. age encrypts to a
*public* key, and in the private repo every reader has everyone's public key —
so anyone with read access could craft a message that arrived as
`"from": "ax41"`. The auto-responder acted on those, and governance hands out
work over the same channel.

Each agent now also has an ed25519 **signing** key. The plaintext is signed
before encryption, and the signature covers id, sender, recipient, timestamp
and text — so a captured envelope can neither be readdressed nor attributed
to someone else.

### What you have to do

```bash
agent-mesh sync            # creates the signing key and publishes it
agent-mesh doctor --security
```

That is all. The key is generated on first sync and its public half goes into
`vault/keys/<agent>.ssh.pub` next to the age key.

### What you will see in the meantime

Until an agent has synced once, its messages show as **UNSIGNED** on the
receiving side — readable, clearly marked, but not treated as proven. The
auto-responder does not reply to them. Messages sent before this release stay
unsigned forever; that is honest rather than convenient.

Inbox markers:

| Marker | Meaning |
|---|---|
| ✅ signiert | Sender proven, content unchanged |
| ⚠️ UNSIGNIERT | No signature — sender not established |
| 🚨 SIGNATUR UNGÜLTIG | Forged, tampered with, or readdressed |
| ⏳ älter als 7 Tage | Validly signed but stale |

A signing key change is treated like an age key change: encryption and
verification stop with a warning until you accept it deliberately
(`agent-mesh vault repin <agent>`).

## v1.14.0

**Releases are signed from now on. One maintainer action is required before
this version can ever be superseded.**

### Maintainer: set up release signing (do this first)

Agents now install only what is tagged and signed with a trusted key, and they
take the content from the **tag**, not from `main`. Write access to the
repository no longer equals root on every machine.

Until `.github/allowed_signers` lists a real key, agents refuse every update —
deliberately, because an empty trust base must block rather than wave things
through. Full walkthrough: [docs/RELEASING.md](docs/RELEASING.md).

```bash
ssh-keygen -t ed25519 -f ~/.ssh/agent-mesh-release -C "release@moinsen.dev"
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/agent-mesh-release.pub
printf 'release@moinsen.dev %s\n' "$(cat ~/.ssh/agent-mesh-release.pub)" \
  > .github/allowed_signers
git commit -am "chore: add release signing key" && git push
git tag -s v1.14.0 -m "agent-mesh v1.14.0" && git push origin --follow-tags
```

### Every agent: adopt the trust base

```bash
agent-mesh trust              # shows the keys, asks nothing on first use
agent-mesh trust --show       # review later
agent-mesh doctor --security  # confirms the release tag verifies
```

This is a one-time step. Afterwards updates run as before — they just refuse
anything that is not signed by a key you already trusted.

### What agents now reject

- A release tag signed with an unknown key
- A version with no tag at all
- A `VERSION` older than the installed one (downgrade protection — a tampered
  `main` could otherwise point at an old, validly signed release and reopen a
  patched hole)
- Content from `main` that differs from the signed tag

All four were tested against a real signing setup before shipping.

## v1.13.0

**Security release. The relay protocol changed — please read this once.**

### 1. The shared relay token is gone (no replacement needed)

Until now every agent authenticated with `HMAC(shared_secret, agent_name)`.
Because all agents needed the same secret, any agent could compute any other
agent's token — collect their messages and send under their name.

Now the relay encrypts a random nonce to your registered age public key and
you decrypt it with your private key. No secret is transmitted at all.

**What you have to do — on EVERY agent:**

```bash
# 1. Remove the token line from your config (it does nothing now):
sed -i.bak '/^AGENT_MESH_RELAY_TOKEN=/d' ~/.agent-mesh/agent-mesh.conf

# 2. Verify your key is in place and the relay knows it:
agent-mesh doctor --security
```

`AGENT_MESH_RELAY_URL` stays as it is.

**What you do NOT have to do:** nothing to redistribute, nothing to rotate.
The key you authenticate with is the same one you have had since `init`.

**While the hub is still on the old version:** peer delivery fails and `send`
falls back to Git automatically (60s). Nothing is lost, so the rollout order
does not matter.

### 2. HUB only: switch the relay service over

The relay now needs read access to the key registry instead of a token:

```bash
sudo cp ~/.agent-mesh/framework/agent-mesh-relay.service /etc/systemd/system/
sudo rm -f /etc/agent-mesh/relay.env          # held nothing but the old token
sudo systemctl daemon-reload
sudo systemctl restart agent-mesh-relay
sudo systemctl status agent-mesh-relay --no-pager | head -5
```

Important: `--host` now defaults to `127.0.0.1` instead of `0.0.0.0`. If
agents reach the relay over Tailscale, put the **Tailscale IP** in the unit
(e.g. `--host 100.84.254.40`) — not `0.0.0.0`. The documentation always
promised "reachable over Tailscale only"; the code did not keep that promise
and the port was public.

Then retire the old secret — it has no function left and should not sit
around looking valid:

```bash
cd ~/.agent-mesh/memories
git rm -q vault/secrets/relay-token.yaml 2>/dev/null \
  && git commit -q -m "vault: remove relay-token (v1.13.0 uses age challenge-response)" \
  && git push
```

### 3. Key pinning is now active (happens by itself)

The first time you `send` to an agent or run `vault set` for it, your agent
records that agent's public key locally (`PIN_<agent>=` in
`agent-mesh.conf`). If the key changes later, encryption stops with a clear
message instead of silently encrypting to a new — possibly substituted — key.

- Review pins: `agent-mesh vault pins`
- Accept a **genuine** key change: `agent-mesh vault repin <agent>`

Accepting asks you to confirm over a second channel. That prompt is meant
seriously: this is exactly where an attack would become visible.

### 4. `vault revoke` no longer spreads secrets widely

Previously `revoke` re-encrypted every secret to ALL remaining keys — turning
"hub only" into "everyone" without saying so. Now each secret keeps its own
recipient list, minus the revoked agent.

**One-time check recommended** if a `revoke` ever ran in the past:

```bash
agent-mesh vault list           # which secrets can you read?
```

If you can read secrets that are none of your business, the old behaviour
spread them. Set those once more:
`agent-mesh vault set <key> <value> --for <the-right-agents>`

### 5. HUB only: deploy and restart the dashboard

The GitHub OAuth login from v1.11.0 had two flaws that combined badly: the
OAuth `state` values lived in the same map as real sessions, and
`requireAuth` only checked that an entry existed and had not expired. A
`GET /login` returns the `state` openly in the redirect — with the cookie
`mesh_session=oauth_<state>` anyone reached all data without logging in. At
the same time the real login did not work at all (`awaitFetch` was never
awaited).

**Careful, there is a chicken-and-egg problem here:** until v1.12
`install_framework` only copied `agent-mesh`, `*.sh` and `*.py` — **never
`.js`**. The dashboard was therefore never distributed by the updater. From
v1.13.0 `.js` is included, but the update *to* v1.13.0 still runs the old
copy loop. This one time the file has to be moved by hand:

```bash
# 1. Take the file from the freshly pulled framework clone
sudo cp ~/.agent-mesh/framework/agent-mesh-dashboard.js /usr/local/bin/
sudo chmod +x /usr/local/bin/agent-mesh-dashboard.js

# 2. What is the service called? (There is no .service file in the repo —
#    the unit was created by hand on the hub.)
systemctl list-units --type=service | grep -i -E 'dashboard|mesh-console'

# 3. Restart with the name you found and check
sudo systemctl restart <the-name-you-found>
sudo systemctl status  <the-name-you-found> --no-pager | head -5
```

Verify the bypass is really closed — from outside, against the real URL:

```bash
STATE=$(curl -s -i https://mesh-console.moinsen.dev/login \
        | grep -i '^location:' | grep -oE 'state=[a-f0-9]+' | cut -d= -f2)
curl -s -o /dev/null -w '%{http_code}\n' \
     -H "Cookie: mesh_session=oauth_$STATE" \
     https://mesh-console.moinsen.dev/api/status
```
Expected: **401**. If you get **200**, the old code is still running and step
1 did not land.

Anyone logged in meanwhile has to log in again — old sessions are gone with
the restart. That is intended.

### 6. Fixed along the way

- `vault revoke` and `agent-mesh connect` never ran through on **macOS**
  (`${var,,}` is bash 4 syntax, macOS ships bash 3.2). Portable now.
- Dashboard: agent names no longer pass through a shell, and no longer enter
  the page as HTML.
- Dashboard: the membership check ran into a 10-**millisecond** timeout and
  therefore always failed. Now 10 seconds.
- `agent-mesh update` now distributes `.js` files as well. Before, it
  reported success without ever touching the dashboard.
