# M1-Prompt: Agent-Mesh vollständig einrichten (für den Hermes-Agent auf dem Mac)

Führe die folgenden Schritte in dieser Reihenfolge aus. Prüfe nach jedem Schritt
das Ergebnis. Bei Fehlern: nicht abbrechen, sondern den angegebenen Fix
anwenden und weitermachen. Am Ende melde dich im Mesh.

## Schritt 1 — Framework aktualisieren
```bash
agent-mesh update
```
**Erwartet:** „✅ Update abgeschlossen — neue Version: v1.2.2"
**Falls Fehler:** `git pull --rebase` beschwert sich über unstaged changes →
der Fix ist automatisch (stash + hard-reset). Falls `agent-mesh` nicht
gefunden: neu installieren:
```bash
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/install.sh | bash
```

## Schritt 2 — Version verifizieren
```bash
agent-mesh update --check
```
**Erwartet:** „Framework ist aktuell (v1.2.2)"

## Schritt 3 — Wartende Nachrichten holen + lesen
```bash
agent-mesh sync
agent-mesh inbox
```
**Erwartet:** 2 Nachrichten von ax41 (Update-Auftrag + watch-Auftrag).
**Falls Inbox leer:** `cd ~/.agent-mesh/memories && git pull --rebase origin main` dann erneut `agent-mesh inbox`.

## Schritt 4 — Auto-Sync-Daemon starten (damit du ab jetzt selbstständig bleibst!)
```bash
# launchd-Agent einrichten (läuft dauerhaft, startet bei Login neu):
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/dev.moinsen.agentmesh.watch.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.moinsen.agentmesh.watch</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>agent-mesh watch 60</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${HOME}/.agent-mesh/watch.log</string>
  <key>StandardErrorPath</key><string>${HOME}/.agent-mesh/watch.log</string>
</dict>
</plist>
PLIST
launchctl unload ~/Library/LaunchAgents/dev.moinsen.agentmesh.watch.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/dev.moinsen.agentmesh.watch.plist
```
**Verifizieren:**
```bash
launchctl list | grep agentmesh   # → dev.moinsen.agentmesh.watch  (PID vorhanden)
```

## Schritt 5 — Bestätigung ans Mesh senden
```bash
agent-mesh send ax41 "UPDATE-OK: v1.2.2 läuft, LaunchAgent aktiv, watch alle 60s. Ab jetzt autonom im Mesh. — dev-docker"
```

## Schritt 6 — Rolle setzen (optional, empfohlen)
```bash
agent-mesh role worker   # oder specialist, wenn du ein Spezialgebiet hast
agent-mesh status        # zeigt: ax41 [hub] · dev-docker [worker]
```

## Zusammenfassung (was danach automatisch läuft)
- `agent-mesh watch 60` via LaunchAgent → holt Nachrichten + Sync alle 60s
- Self-Update → prüft stündlich das Framework-Repo, aktualisiert sich selbst
- Nachrichten/Vault → verschlüsselt, nur für dich lesbar

**Fertig, wenn:** Schritt 5 erfolgreich („✅ Verschlüsselte Nachricht an 'ax41' gesendet").
