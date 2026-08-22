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
FRAMEWORK_DIR="$AGENT_MESH_HOME/framework"
BIN="${AGENT_MESH_BIN:-$(dirname "$(readlink -f "$0")")/agent-mesh}"
GH_ORG="${AGENT_MESH_GH_ORG:-moinsen-dev}"
PUBLIC_REPO="agent-mesh"

INTERVAL="${1:-60}"
# Nur positive Zahlen
case "$INTERVAL" in
  *[!0-9]*|'') echo "❌ Intervall muss eine Zahl sein (Sekunden)"; exit 1 ;;
esac
# Self-Update-Intervall: alle UPDATE_EVERY Zyklen das Framework prüfen
# (Default: alle 60 Zyklen → bei 60s-Intervall ≈ stündlich; konfigurierbar)
UPDATE_EVERY="${AGENT_MESH_UPDATE_EVERY:-60}"

[ -f "$CONF" ] || { echo "❌ Nicht initialisiert — zuerst: agent-mesh init <name>"; exit 1; }
[ -d "$MEMORIES_DIR/.git" ] || { echo "❌ Repo-Klon fehlt — zuerst: agent-mesh sync"; exit 1; }

AGENT_NAME=$(grep "^AGENT_NAME=" "$CONF" | cut -d= -f2- || true)
# SSH-Key-Option laden (falls gesetzt)
SSH_LINE=$(grep "^GIT_SSH_COMMAND=" "$CONF" | cut -d= -f2- || true)
[ -n "$SSH_LINE" ] && export GIT_SSH_COMMAND="$SSH_LINE"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
log "🔄 agent-mesh watch gestartet (Agent: $AGENT_NAME, Intervall: ${INTERVAL}s, Self-Update: alle ${UPDATE_EVERY} Zyklen)"

# ── Self-Update: Framework vom public Repo prüfen + bei neuer Version updaten ──
check_framework_update() {
  # Framework-Klon vorhanden?
  if [ ! -d "$FRAMEWORK_DIR/.git" ]; then
    # Klonen (via ssh, fallback https)
    if ! git clone "git@github.com:$GH_ORG/$PUBLIC_REPO.git" "$FRAMEWORK_DIR" 2>/dev/null \
      && ! git clone "https://github.com/$GH_ORG/$PUBLIC_REPO.git" "$FRAMEWORK_DIR" 2>/dev/null; then
      log "⚠️  Framework-Klon fehlgeschlagen — Self-Update übersprungen"
      return
    fi
  fi
  # VERSION vergleichen (lokale VERSION-Datei vs. origin/main)
  local local_v remote_v
  local_v=$(cat "$FRAMEWORK_DIR/VERSION" 2>/dev/null || echo "0.0.0")
  remote_v=$(cd "$FRAMEWORK_DIR" && git fetch origin main --quiet 2>/dev/null; \
             git show origin/main:VERSION 2>/dev/null || echo "$local_v")
  if [ "$local_v" != "$remote_v" ]; then
    log "⬆️  Framework-Update: v$local_v → v$remote_v — aktualisiere…"
    # pull + install (agent-mesh update macht genau das)
    "$BIN" update >> "$AGENT_MESH_HOME/watch.log" 2>&1 \
      || log "⚠️  Framework-Update fehlgeschlagen (Log: $AGENT_MESH_HOME/watch.log)"
    log "✅ Framework aktualisiert auf v$remote_v"
  fi
}

# Zykluszähler für Self-Update
CYCLE=0

while true; do
  CYCLE=$((CYCLE+1))
  # 0. Self-Update: Framework prüfen (nicht bei jedem Zyklus — sparsam)
  if [ $((CYCLE % UPDATE_EVERY)) -eq 0 ]; then
    check_framework_update
  fi
  # 1. Nur prüfen: hat sich der Remote geändert? (billig)
  if (cd "$MEMORIES_DIR" && git fetch origin main --quiet 2>/dev/null); then
    BEHIND=$(cd "$MEMORIES_DIR" && git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    if [ "${BEHIND:-0}" -gt 0 ]; then
      log "⬆️  $BEHIND neue Commit(s) — synce…"
      "$BIN" sync >> "$AGENT_MESH_HOME/watch.log" 2>&1 || log "⚠️  sync meldete Fehler (Log: $AGENT_MESH_HOME/watch.log)"
      # Inbox anzeigen, falls Nachrichten da sind
      INBOX=$("$BIN" inbox 2>/dev/null | grep -c "──" || true)
      [ "${INBOX:-0}" -gt 0 ] && log "📬 $INBOX Nachricht(en) in der Mailbox (agent-mesh inbox)"
      # Auto-Respond: neue Nachrichten beantworten (Swarm-Intelligenz!)
      "$BIN" respond >> "$AGENT_MESH_HOME/watch.log" 2>&1 \
        || log "⚠️  Auto-Respond meldete Fehler (Log: $AGENT_MESH_HOME/watch.log)"
    fi
  fi
  # Wartungssignale prüfen (Broadcast "agent-mesh maintenance")
  "$BIN" maintenance-run >> "$AGENT_MESH_HOME/watch.log" 2>&1 || true
  # Peer-Empfang: Relay-Queue leeren (Echtzeit-Nachrichten, die wir verpasst haben)
  "$BIN" peer-recv >> "$AGENT_MESH_HOME/watch.log" 2>&1 || true
  sleep "$INTERVAL"
done
}
