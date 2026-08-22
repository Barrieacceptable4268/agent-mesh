#!/usr/bin/env bash
# agent-mesh-watch — Polling-Daemon: hält den Agent automatisch synchron.
#
# Prüft alle INTERVAL Sekunden, ob sich das private Repo geändert hat
# (git fetch + log-Check — kein Voll-Sync bei jeder Runde), und stößt
# nur dann agent-mesh sync an. So bleibt jeder Agent OHNE Zutun aktuell:
#   - Neue Nachrichten (A2A-Mailbox) kommen in Sekunden/Minuten an
#   - Wissen/Skills anderer Agents werden übernommen
#   - Der Hub (Webhook) reagiert sofort; alle anderen via Polling
#
# Usage:
#   agent-mesh watch [interval-sekunden]   # Default 60
#   agent-mesh watch 300                   # alle 5 Minuten
#
# Als systemd/Cron/launchd/Task-Scheduler einrichten — läuft dann dauerhaft.

set -euo pipefail

# In Funktion wrappen — beim Sourcen darf NICHTS laufen (nur bei `watch`-Dispatch)
cmd_watch() {
# Konfiguration laden (gleiche Logik wie agent-mesh)
AGENT_MESH_HOME="${AGENT_MESH_HOME:-$HOME/.agent-mesh}"
CONF="$AGENT_MESH_HOME/agent-mesh.conf"
MEMORIES_DIR="$AGENT_MESH_HOME/memories"
BIN="${AGENT_MESH_BIN:-$(dirname "$(readlink -f "$0")")/agent-mesh}"

INTERVAL="${1:-60}"
# Nur positive Zahlen
case "$INTERVAL" in
  *[!0-9]*|'') echo "❌ Intervall muss eine Zahl sein (Sekunden)"; exit 1 ;;
esac

[ -f "$CONF" ] || { echo "❌ Nicht initialisiert — zuerst: agent-mesh init <name>"; exit 1; }
[ -d "$MEMORIES_DIR/.git" ] || { echo "❌ Repo-Klon fehlt — zuerst: agent-mesh sync"; exit 1; }

AGENT_NAME=$(grep "^AGENT_NAME=" "$CONF" | cut -d= -f2- || true)
# SSH-Key-Option laden (falls gesetzt)
SSH_LINE=$(grep "^GIT_SSH_COMMAND=" "$CONF" | cut -d= -f2- || true)
[ -n "$SSH_LINE" ] && export GIT_SSH_COMMAND="$SSH_LINE"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
log "🔄 agent-mesh watch gestartet (Agent: $AGENT_NAME, Intervall: ${INTERVAL}s)"

while true; do
  # 1. Nur prüfen: hat sich der Remote geändert? (billig)
  if (cd "$MEMORIES_DIR" && git fetch origin main --quiet 2>/dev/null); then
    BEHIND=$(cd "$MEMORIES_DIR" && git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    if [ "${BEHIND:-0}" -gt 0 ]; then
      log "⬆️  $BEHIND neue Commit(s) — synce…"
      "$BIN" sync >> "$AGENT_MESH_HOME/watch.log" 2>&1 || log "⚠️  sync meldete Fehler (Log: $AGENT_MESH_HOME/watch.log)"
      # Inbox anzeigen, falls Nachrichten da sind
      INBOX=$("$BIN" inbox 2>/dev/null | grep -c "──" || true)
      [ "${INBOX:-0}" -gt 0 ] && log "📬 $INBOX Nachricht(en) in der Mailbox (agent-mesh inbox)"
    fi
  fi
  sleep "$INTERVAL"
done
}
