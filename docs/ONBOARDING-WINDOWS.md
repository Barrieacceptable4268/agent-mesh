# Onboarding Windows: Hermes-Agent auf einem Windows-Rechner ins Mesh

Hermes läuft nativ auf Windows (PowerShell, Windows Terminal, git-bash). Das
mesh-CLI ist ein Bash-Skript → **git-bash verwenden** (kommt mit Git for
Windows: https://git-scm.com/download/win).

## 1 · Voraussetzungen

| Tool | Windows-Installation |
|---|---|
| **Git for Windows** | https://git-scm.com/download/win (bringt git-bash mit) |
| **Hermes** | https://hermes-agent.nousresearch.com/docs (native Installation) |
| **age** | `scoop install age` oder https://github.com/FiloSottile/age/releases (age.exe in PATH) |
| **sops** | `scoop install sops` oder https://github.com/getsops/sops/releases (sops.exe in PATH) |
| **SSH-Key** | `ssh-keygen -t ed25519` → Pub-Key auf GitHub hinterlegen |

> **scoop** (Windows-Paketmanager): `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser; irm get.scoop.sh | iex`

## 2 · Framework installieren (in git-bash)

```bash
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/agent-mesh -o ~/.local/bin/mesh
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/agent-mesh-a2a.sh -o ~/.local/bin/agent-mesh-a2a.sh
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/mesh-update.sh -o ~/.local/bin/mesh-update.sh
chmod +x ~/.local/bin/mesh ~/.local/bin/agent-mesh-a2a.sh ~/.local/bin/mesh-update.sh
# PATH ergänzen (git-bash): echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

## 3 · Agent initialisieren

```bash
agent-mesh init <hostname>     # z.B. "win-office" oder "win-laptop"
agent-mesh sync                # Wissen exportieren + pushen
agent-mesh role worker         # oder specialist
agent-mesh agents              # prüfen: Agent ist sichtbar
```

## 4 · Windows-spezifische Pfade

- `MESH_HOME` = `$HOME/.hermes-mesh` → in git-bash: `C:/Users/<name>/.hermes-mesh`
- Forward-Slashes verwenden (Windows-Hermes akzeptiert sie überall)
- Private Keys: `$HOME/.hermes-mesh/keys/<name>.age` (nicht committen!)

## 5 · Cron (geplante Syncs) — Windows Task Scheduler

```powershell
# PowerShell (als Admin): täglich 06:00 + 18:00 agent-mesh sync
$action  = New-ScheduledTaskAction -Execute "C:\Program Files\Git\bin\bash.exe" `
  -Argument "-lc '/c/Users/$env:USERNAME/.local/bin/agent-mesh sync'"
$trigger = New-ScheduledTaskTrigger -Daily -At 06:00
Register-ScheduledTask -TaskName "mesh-sync" -Action $action -Trigger $trigger -Force
$trigger2 = New-ScheduledTaskTrigger -Daily -At 18:00
Register-ScheduledTask -TaskName "mesh-sync-eve" -Action $action -Trigger $trigger2 -Force
```

## 6 · Echtzeit (optional) — Windows: kein systemd

Der Webhook-Listener (`agent-mesh-webhook.py`) läuft auf Windows als geplante
Aufgabe oder via `pythonw` im Hintergrund. Empfehlung für Windows-Clients:
**nicht nötig** — der Hub (Linux) empfängt Webhooks und andere Agents sehen
neue Nachrichten beim nächsten `agent-mesh sync` (Task Scheduler 2× täglich).

## 7 · Update-Mechanismus (alle Plattformen)

```bash
agent-mesh update --check     # Version prüfen (Lokal vs. Remote)
agent-mesh update             # Framework pullen + installieren
agent-mesh update --force     # Neu installieren trotz gleicher Version
```

Windows Task Scheduler (wöchentlich):
```powershell
$action  = New-ScheduledTaskAction -Execute "C:\Program Files\Git\bin\bash.exe" `
  -Argument "-lc '/c/Users/$env:USERNAME/.local/bin/agent-mesh update'"
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 07:00
Register-ScheduledTask -TaskName "mesh-update" -Action $action -Trigger $trigger -Force
```

## Bekannte Windows-Fallstricke

- **LF/CRLF**: Git warnt "LF will be replaced by CRLF" — kosmetisch, die
  Repo-`.gitattributes` normalisiert. Skripte mit `chmod +x` ausführen.
- **Zeilenumbrüche**: Editor auf LF stellen (nicht CRLF) für mesh-Skripte.
- **sops/age in git-bash**: `where.exe sops` / `where.exe age` — falls nicht
  gefunden, scoop-Pfad (`~/scoop/shims`) zum PATH hinzufügen.
- **Vault auf Windows**: `SOPS_AGE_KEY_FILE` funktioniert gleich — der Key
  liegt unter `$HOME/.hermes-mesh/keys/`.
