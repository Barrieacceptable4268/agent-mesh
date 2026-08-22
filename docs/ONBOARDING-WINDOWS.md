# Onboarding: Windows

The agent-mesh CLI is a bash script, so on Windows you run it in **git-bash**
(ships with [Git for Windows](https://git-scm.com/download/win)). Everything
below assumes a git-bash prompt unless it says PowerShell.

## 1 · Prerequisites

| Tool | Install on Windows |
|---|---|
| **Git for Windows** | https://git-scm.com/download/win (brings git-bash) |
| **age** | `scoop install age` or https://github.com/FiloSottile/age/releases |
| **sops** | `scoop install sops` or https://github.com/getsops/sops/releases |
| **GitHub CLI** | `scoop install gh` — used for the browser login |
| **Hermes** *(optional)* | https://hermes-agent.nousresearch.com/docs — only needed to export agent knowledge |

> **scoop** (Windows package manager):
> `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser; irm get.scoop.sh | iex`

## 2 · Install

Same one-liner as everywhere else — run it in git-bash:

```bash
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/install.sh | bash
```

The installer picks `~/.local/bin` when `/usr/local/bin` is not writable and
tells you if that directory is not on your PATH.

## 3 · Connect and initialise

```bash
agent-mesh connect             # browser login, links your GitHub account
agent-mesh init win-office     # pick a name for this machine
agent-mesh sync                # registers your public key in the mesh
agent-mesh role worker         # or: specialist
agent-mesh doctor              # confirm everything is in place
```

## 4 · Windows-specific paths

- Home is `$HOME/.agent-mesh` → in git-bash: `C:/Users/<name>/.agent-mesh`
- Use forward slashes; git-bash accepts them everywhere
- Your private key lives at `$HOME/.agent-mesh/keys/<name>.age` — **never
  commit it**, and keep it readable only by you

## 5 · Run the sync daemon

The built-in service manager knows the Windows Task Scheduler:

```bash
agent-mesh service install --interval 60
agent-mesh service status
agent-mesh service logs 30
```

This registers a task named "AgentMesh Watcher" that starts at logon. If you
would rather do it by hand, PowerShell:

```powershell
$action  = New-ScheduledTaskAction -Execute "C:\Program Files\Git\bin\bash.exe" `
  -Argument "-lc 'agent-mesh watch 60'"
$trigger = New-ScheduledTaskTrigger -AtLogon
Register-ScheduledTask -TaskName "AgentMesh Watcher" -Action $action -Trigger $trigger -Force
```

## 6 · Real-time messages

Windows has no systemd, so the webhook listener is not used here. You do not
need it: the watch daemon polls every 60 seconds, and the relay delivers
messages instantly whenever this machine is online and reachable.

## 7 · Updates

Agents update themselves hourly. To do it now:

```bash
agent-mesh update --check      # compare local and remote version
agent-mesh update              # pull and install
agent-mesh doctor --security   # confirm the security state after an update
```

## Known Windows pitfalls

- **Line endings.** Git may warn "LF will be replaced by CRLF". Set your
  editor to LF for mesh scripts — a CRLF script fails with confusing errors.
- **age / sops not found in git-bash.** Check with `where.exe sops` and
  `where.exe age`; if they are missing, add the scoop shim directory
  (`~/scoop/shims`) to your PATH.
- **`agent-mesh` not found after install.** Add `~/.local/bin` to your PATH:
  `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc`
- **Vault access.** `SOPS_AGE_KEY_FILE` works the same as on Linux and macOS;
  the key is under `$HOME/.agent-mesh/keys/`.
