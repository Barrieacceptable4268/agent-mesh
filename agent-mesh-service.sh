#!/usr/bin/env bash
# agent-mesh-service — plattformübergreifender Service-Manager für den watch.
#
# Verwaltet `agent-mesh watch <interval>` als Hintergrund-Dienst:
#   Linux:   systemd-Unit    (agent-mesh-watch.service)
#   macOS:   LaunchAgent     (dev.moinsen.agentmesh.watch.plist)
#   Windows: Task Scheduler  (AgentMesh Watcher, schtasks.exe)
#
# Usage:
#   agent-mesh service install [--interval 60]
#   agent-mesh service status
#   agent-mesh service logs [n]
#   agent-mesh service restart
#   agent-mesh service uninstall

set -euo pipefail

SVC_NAME="agent-mesh-watch"
SVC_LABEL="dev.moinsen.agentmesh.watch"
WIN_TASK="AgentMesh Watcher"
INTERVAL="${AGENT_MESH_WATCH_INTERVAL:-60}"

# Plattform erkennen
os_name() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    Darwin) echo "macos" ;;
    *) echo "linux" ;;
  esac
}

svc_install() {
  # --interval <n> parsen
  local interval="$INTERVAL"
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) interval="${2:-$INTERVAL}"; shift 2 ;;
      *) interval="$1"; shift ;;
    esac
  done
  local os; os=$(os_name)
  case "$os" in
    linux)
      if command -v systemctl >/dev/null 2>&1; then
        local unit="/etc/systemd/system/$SVC_NAME.service"
        # SECURITY (Audit-Befund 11): frueher wurde die Unit nach
        # /tmp/agent-mesh-watch.service geschrieben und von dort als root nach
        # /etc/systemd/system kopiert. Zwischen Schreiben und Kopieren konnte
        # ein lokaler Nutzer die Datei austauschen — oder vorab einen Symlink
        # dorthin legen — und sich so eine beliebige root-Unit installieren.
        # Jetzt direkt ans Ziel, ohne Umweg ueber ein world-writable Verzeichnis.
        if [ ! -w "$(dirname "$unit")" ]; then
          echo "❌ Keine Rechte für $unit — sudo nötig"
          return 1
        fi
        cat > "$unit" << EOF
[Unit]
Description=Agent-Mesh Watch (Auto-Sync + Self-Update)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=$HOME
Environment=PATH=/usr/local/bin:/usr/local/lib/hermes-agent/venv/bin:/usr/bin:/bin:/opt/homebrew/bin
Environment=AGENT_MESH_UPDATE_EVERY=${AGENT_MESH_UPDATE_EVERY:-60}
ExecStart=$(command -v agent-mesh) watch $interval
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "$unit" 2>/dev/null || true
        systemctl daemon-reload
        systemctl enable $SVC_NAME >/dev/null 2>&1
        systemctl restart $SVC_NAME
        echo "✅ systemd: $SVC_NAME aktiv (watch $interval)"
      else
        echo "❌ systemd nicht gefunden — manuell: agent-mesh watch $interval &"
      fi
      ;;
    macos)
      local plist="$HOME/Library/LaunchAgents/$SVC_LABEL.plist"
      mkdir -p "$(dirname "$plist")"
      cat > "$plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SVC_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>agent-mesh watch $interval</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    <key>PYTHON_BIN</key><string>python3</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$AGENT_MESH_HOME/watch.log</string>
  <key>StandardErrorPath</key><string>$AGENT_MESH_HOME/watch.log</string>
</dict>
</plist>
PLIST
      launchctl unload "$plist" 2>/dev/null || true
      launchctl load "$plist" 2>/dev/null
      echo "✅ launchd: $SVC_LABEL aktiv (watch $interval)"
      ;;
    windows)
      # Task Scheduler via schtasks.exe (kein Admin nötig für /SC ONLOGON im User-Kontext)
      local bash_path
      bash_path=$(command -v bash 2>/dev/null || echo "C:\\Program Files\\Git\\bin\\bash.exe")
      local cmd="\"$bash_path\" -lc \"agent-mesh watch $interval\""
      if schtasks //Query //TN "$WIN_TASK" >/dev/null 2>&1; then
        schtasks //Delete //TN "$WIN_TASK" //F >/dev/null 2>&1
      fi
      schtasks //Create //TN "$WIN_TASK" //TR "$cmd" //SC ONLOGON //RL LIMITED //F >/dev/null 2>&1 \
        || { echo "❌ Task-Scheduler-Anlage fehlgeschlagen"; return 1; }
      # Sofort starten (ohne auf Logon zu warten)
      schtasks //Run //TN "$WIN_TASK" >/dev/null 2>&1 || true
      echo "✅ Task Scheduler: '$WIN_TASK' aktiv (watch $interval, bei Logon)"
      ;;
  esac
}

svc_status() {
  local os; os=$(os_name)
  case "$os" in
    linux)
      if systemctl is-active $SVC_NAME >/dev/null 2>&1; then
        echo "✅ $SVC_NAME: active ($(systemctl show $SVC_NAME -p ExecStart --value 2>/dev/null | sed 's/.*watch/watch/'))"
      else
        echo "❌ $SVC_NAME: inactive — 'agent-mesh service install' ausführen"
      fi
      ;;
    macos)
      if launchctl list 2>/dev/null | grep -q "$SVC_LABEL"; then
        echo "✅ $SVC_LABEL: aktiv"
      else
        echo "❌ $SVC_LABEL: nicht geladen — 'agent-mesh service install' ausführen"
      fi
      ;;
    windows)
      if schtasks //Query //TN "$WIN_TASK" >/dev/null 2>&1; then
        local state
        state=$(schtasks //Query //TN "$WIN_TASK" //FO LIST 2>/dev/null | grep -i "Status" | head -1 | cut -d: -f2- | xargs)
        echo "✅ '$WIN_TASK': $state"
      else
        echo "❌ '$WIN_TASK': nicht eingerichtet — 'agent-mesh service install' ausführen"
      fi
      ;;
  esac
}

svc_logs() {
  local n="${1:-30}"
  local os; os=$(os_name)
  case "$os" in
    linux) journalctl -u $SVC_NAME --no-pager -n "$n" 2>&1 || echo "Keine Logs" ;;
    macos) tail -n "$n" "$AGENT_MESH_HOME/watch.log" 2>/dev/null || echo "Keine Logs ($AGENT_MESH_HOME/watch.log)" ;;
    windows) tail -n "$n" "$AGENT_MESH_HOME/watch.log" 2>/dev/null || echo "Keine Logs — Task schreibt nach $AGENT_MESH_HOME/watch.log" ;;
  esac
}

svc_restart() {
  local os; os=$(os_name)
  case "$os" in
    linux) systemctl restart $SVC_NAME && echo "✅ $SVC_NAME neu gestartet" ;;
    macos)
      launchctl unload "$HOME/Library/LaunchAgents/$SVC_LABEL.plist" 2>/dev/null || true
      launchctl load "$HOME/Library/LaunchAgents/$SVC_LABEL.plist" 2>/dev/null && echo "✅ $SVC_LABEL neu gestartet"
      ;;
    windows)
      schtasks //End //TN "$WIN_TASK" >/dev/null 2>&1 || true
      schtasks //Run //TN "$WIN_TASK" >/dev/null 2>&1 && echo "✅ '$WIN_TASK' neu gestartet"
      ;;
  esac
}

svc_uninstall() {
  local os; os=$(os_name)
  case "$os" in
    linux)
      systemctl stop $SVC_NAME 2>/dev/null || true
      systemctl disable $SVC_NAME 2>/dev/null || true
      rm -f "/etc/systemd/system/$SVC_NAME.service"
      systemctl daemon-reload
      echo "✅ $SVC_NAME entfernt"
      ;;
    macos)
      launchctl unload "$HOME/Library/LaunchAgents/$SVC_LABEL.plist" 2>/dev/null || true
      rm -f "$HOME/Library/LaunchAgents/$SVC_LABEL.plist"
      echo "✅ $SVC_LABEL entfernt"
      ;;
    windows)
      schtasks //Delete //TN "$WIN_TASK" //F >/dev/null 2>&1 && echo "✅ '$WIN_TASK' entfernt" || echo "⚠️ Task nicht gefunden"
      ;;
  esac
}

cmd_service() {
  load_conf
  local sub="${1:-}"
  shift 2>/dev/null || true
  case "$sub" in
    install)  svc_install "$@" ;;
    status)   svc_status ;;
    logs)     svc_logs "${1:-30}" ;;
    restart)  svc_restart ;;
    uninstall) svc_uninstall ;;
    *) echo "Usage: agent-mesh service {install [--interval N]|status|logs [n]|restart|uninstall}" >&2; exit 1 ;;
  esac
}
