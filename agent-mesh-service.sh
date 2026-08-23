#!/usr/bin/env bash
# agent-mesh-service — der Dienst, der einen Agenten im Verbund hält.
#
#   Linux:   systemd-Timer   (agent-mesh-converge.timer + .service)
#   macOS:   LaunchAgent     (dev.moinsen.agentmesh.watch.plist, StartInterval)
#   Windows: Task Scheduler  (AgentMesh Watcher, /SC MINUTE)
#
# ── Warum das ein INTERVALL ist und kein Dauerprozess ──────────────────────
#
# Bis v1.30.1 installierte dieser Manager auf allen drei Plattformen einen
# residenten `agent-mesh watch` — eine `while true`-Schleife, die laufen muss,
# damit der Agent überhaupt etwas mitbekommt. Am 22./23.08.2026 standen zwei
# von sechs Agenten über Nacht still, und jede Plattform hatte ihren eigenen
# Grund dafür:
#
#   macOS    Ein LaunchAgent läuft, solange der Nutzer angemeldet ist. Geht die
#            Maschine schlafen oder meldet sich jemand ab, ist der Prozess weg;
#            KeepAlive bringt ihn nicht über eine Abmeldung.
#   Windows  Die Aufgabe war `/SC ONLOGON` — sie startete den Prozess EINMAL
#            bei der Anmeldung. Stirbt er, kommt bis zur nächsten Anmeldung
#            nichts mehr. Auf einem Server, an dem sich nie jemand anmeldet,
#            heisst das: nie.
#   Linux    systemd mit Restart=always hält durch — aber nur, wenn der Dienst
#            überhaupt installiert wurde. Ein `agent-mesh watch` in einem
#            Terminal stirbt mit dem Terminal.
#
# Ein Intervall hat keine dieser Schwächen. Es gibt keinen Prozess, der
# sterben könnte: Das Betriebssystem ruft alle N Sekunden `agent-mesh converge`
# auf, das ist ein idempotenter Durchlauf, der endet. Fällt einer aus, ist der
# nächste dadurch nicht weniger vollständig. Nach Ruhezustand, Abmeldung oder
# Neustart läuft es weiter, ohne dass jemand etwas tut — launchd holt ein
# verpasstes Intervall beim Aufwachen nach, systemd mit Persistent=true
# ebenfalls.
#
# `agent-mesh watch` bleibt für den Vordergrund: zusehen, was passiert.
#
# Usage:
#   agent-mesh service install [--interval 60]
#   agent-mesh service status
#   agent-mesh service logs [n]
#   agent-mesh service restart
#   agent-mesh service uninstall

set -euo pipefail

SVC_NAME="agent-mesh-converge"
SVC_LEGACY="agent-mesh-watch"       # der residente Dienst bis v1.30.1
SVC_LABEL="dev.moinsen.agentmesh.watch"
WIN_TASK="AgentMesh Watcher"
INTERVAL="${AGENT_MESH_WATCH_INTERVAL:-60}"

os_name() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    Darwin) echo "macos" ;;
    *) echo "linux" ;;
  esac
}

# Der Label bzw. Taskname bleibt absichtlich gleich: `launchctl load` und
# `schtasks /Create /F` ersetzen damit die alte Definition, statt eine zweite
# danebenzustellen. Unter systemd geht das nicht — dort muss die alte Unit
# ausdrücklich abgeräumt werden, sonst laufen Schleife und Timer nebeneinander.
retire_legacy_unit() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl list-unit-files 2>/dev/null | grep "$SVC_LEGACY.service" >/dev/null || return 0
  systemctl stop "$SVC_LEGACY" 2>/dev/null || true
  systemctl disable "$SVC_LEGACY" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SVC_LEGACY.service"
  systemctl daemon-reload 2>/dev/null || true
  echo "  ✓ alter Dauerdienst $SVC_LEGACY.service abgelöst"
}

svc_install() {
  local interval="$INTERVAL"
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) interval="${2:-$INTERVAL}"; shift 2 ;;
      *) interval="$1"; shift ;;
    esac
  done
  case "$interval" in
    *[!0-9]*|'') echo "❌ Intervall muss eine Zahl sein (Sekunden)"; return 1 ;;
  esac

  local self; self=$(command -v agent-mesh 2>/dev/null || echo "agent-mesh")
  local os; os=$(os_name)
  case "$os" in
    linux)
      if ! command -v systemctl >/dev/null 2>&1; then
        echo "❌ systemd nicht gefunden."
        echo "   Ersatzweise per cron:  */5 * * * * $self converge --quiet >> $AGENT_MESH_HOME/watch.log 2>&1"
        return 1
      fi
      local unit="/etc/systemd/system/$SVC_NAME.service"
      local timer="/etc/systemd/system/$SVC_NAME.timer"
      # SECURITY (Audit-Befund 11): direkt ans Ziel schreiben, nie über /tmp —
      # zwischen Schreiben und Kopieren könnte ein lokaler Nutzer die Datei
      # austauschen und sich eine beliebige root-Unit installieren.
      if [ ! -w "$(dirname "$unit")" ]; then
        echo "❌ Keine Rechte für $unit — sudo nötig"
        return 1
      fi
      retire_legacy_unit
      cat > "$unit" << EOF
[Unit]
Description=Agent-Mesh: ein Abgleich mit dem Verbund
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=$HOME
Environment=PATH=/usr/local/bin:/usr/local/lib/hermes-agent/venv/bin:/usr/bin:/bin:/opt/homebrew/bin
ExecStart=$self converge --quiet
EOF
      cat > "$timer" << EOF
[Unit]
Description=Agent-Mesh: Abgleich alle ${interval}s

[Timer]
OnBootSec=60
OnUnitActiveSec=${interval}
# Verpasste Läufe nach Ausfall oder Neustart nachholen — ohne das wäre ein
# Rechner, der eine Nacht aus war, danach genauso still wie vorher.
Persistent=true
Unit=$SVC_NAME.service

[Install]
WantedBy=timers.target
EOF
      chmod 644 "$unit" "$timer" 2>/dev/null || true
      systemctl daemon-reload
      systemctl enable "$SVC_NAME.timer" >/dev/null 2>&1
      systemctl restart "$SVC_NAME.timer"
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
    <string>agent-mesh converge --quiet</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    <key>PYTHON_BIN</key><string>python3</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>$interval</integer>
  <key>StandardOutPath</key><string>$AGENT_MESH_HOME/watch.log</string>
  <key>StandardErrorPath</key><string>$AGENT_MESH_HOME/watch.log</string>
</dict>
</plist>
PLIST
      launchctl unload "$plist" 2>/dev/null || true
      launchctl load "$plist" 2>/dev/null
      ;;
    windows)
      local bash_path
      bash_path=$(command -v bash 2>/dev/null || echo "C:\\Program Files\\Git\\bin\\bash.exe")
      local cmd="\"$bash_path\" -lc \"agent-mesh converge --quiet\""
      # Minuten, nicht Sekunden — und mindestens eine.
      local mins=$(( interval / 60 )); [ "$mins" -lt 1 ] && mins=1
      if schtasks //Query //TN "$WIN_TASK" >/dev/null 2>&1; then
        schtasks //Delete //TN "$WIN_TASK" //F >/dev/null 2>&1
      fi
      # /SC MINUTE statt /SC ONLOGON: die Aufgabe wiederholt sich von selbst.
      # Mit ONLOGON lief sie auf einem Server, an dem sich nie jemand anmeldet,
      # genau nie wieder.
      #
      # Und /RU SYSTEM, weil das ALLEIN noch nicht reicht: ohne /RU gehört die
      # Aufgabe dem angemeldeten Nutzer und läuft nur in dessen Sitzung. Die
      # Wiederholung wäre dann repariert und die Anmeldungs-Abhängigkeit
      # geblieben — derselbe Ausfall, nur später bemerkt. Das war ein Fehler
      # in v1.31.0, gefunden beim Nachrechnen, nicht im Betrieb.
      #
      # SYSTEM braucht erhöhte Rechte. Klappt es nicht, fällt die Anlage auf
      # den Nutzerkontext zurück — aber laut, damit niemand glaubt, die
      # Maschine sei versorgt.
      if ! schtasks //Create //TN "$WIN_TASK" //TR "$cmd" //SC MINUTE //MO "$mins" \
             //RU SYSTEM //RL HIGHEST //F >/dev/null 2>&1; then
        echo "⚠️  Als SYSTEM nicht möglich (Administratorrechte nötig)."
        echo "   Weiche auf den Nutzerkontext aus — die Aufgabe läuft dann NUR,"
        echo "   solange dieser Nutzer angemeldet ist. Für einen Server bitte"
        echo "   einmal in einer Administrator-Konsole wiederholen."
        schtasks //Create //TN "$WIN_TASK" //TR "$cmd" //SC MINUTE //MO "$mins" //RL LIMITED //F >/dev/null 2>&1 \
          || { echo "❌ Task-Scheduler-Anlage fehlgeschlagen"; return 1; }
      fi
      schtasks //Run //TN "$WIN_TASK" >/dev/null 2>&1 || true
      ;;
  esac

  # Melden, was danach GILT — nicht, was getan wurde. Ein eingerichteter
  # Dienst, der nicht läuft, sieht in der Flottenübersicht aus wie gar keiner.
  echo "── Eingerichtet, jetzt geprüft ──"
  svc_status
}

svc_status() {
  local os; os=$(os_name)
  case "$os" in
    linux)
      if systemctl is-active "$SVC_NAME.timer" >/dev/null 2>&1; then
        local nxt
        nxt=$(systemctl show "$SVC_NAME.timer" -p NextElapseUSecRealtime --value 2>/dev/null || true)
        echo "✅ $SVC_NAME.timer: aktiv${nxt:+ — nächster Lauf: $nxt}"
      elif systemctl is-active "$SVC_LEGACY" >/dev/null 2>&1; then
        echo "⚠️  Noch der alte Dauerdienst $SVC_LEGACY — 'agent-mesh service install' löst ihn ab"
      else
        echo "❌ $SVC_NAME.timer: inaktiv — 'agent-mesh service install' ausführen"
      fi
      ;;
    macos)
      if launchctl list 2>/dev/null | grep "$SVC_LABEL" >/dev/null; then
        local iv
        # `|| true` ist hier nicht kosmetisch: findet grep kein StartInterval —
        # also genau im abzulösenden Altfall —, würde `set -e` die Statusausgabe
        # beenden, bevor die Warnung erscheint. Genau so gefunden.
        iv=$(grep -A1 StartInterval "$HOME/Library/LaunchAgents/$SVC_LABEL.plist" 2>/dev/null \
             | grep -oE '[0-9]+' | head -1 || true)
        if [ -n "$iv" ]; then
          echo "✅ $SVC_LABEL: geladen — Abgleich alle ${iv}s"
        else
          echo "⚠️  $SVC_LABEL: geladen, aber noch als Dauerprozess (stirbt bei Abmeldung/Ruhezustand)"
          echo "   Ablösen: agent-mesh service install"
        fi
      else
        echo "❌ $SVC_LABEL: nicht geladen — 'agent-mesh service install' ausführen"
      fi
      ;;
    windows)
      if schtasks //Query //TN "$WIN_TASK" >/dev/null 2>&1; then
        local out state sched
        out=$(schtasks //Query //TN "$WIN_TASK" //FO LIST //V 2>/dev/null || true)
        state=$(printf '%s\n' "$out" | grep -i "^Status" | head -1 | cut -d: -f2- | xargs || true)
        sched=$(printf '%s\n' "$out" | grep -iE "^Schedule Type|^Zeitplantyp" | head -1 | cut -d: -f2- | xargs || true)
        echo "✅ '$WIN_TASK': ${state:-?}${sched:+ ($sched)}"
        case "$(printf '%s' "$sched" | tr '[:upper:]' '[:lower:]')" in
          *logon*|*anmeld*)
            echo "⚠️  Läuft nur bei der Anmeldung — stirbt der Lauf, kommt bis zur nächsten"
            echo "   Anmeldung nichts mehr. Ablösen: agent-mesh service install" ;;
        esac
        # Der Zeitplan allein sagt nichts: eine minütliche Aufgabe im
        # Nutzerkontext ruht trotzdem, sobald sich niemand anmeldet.
        local runas
        runas=$(printf '%s\n' "$out" | grep -iE "^Run As User|^Als Benutzer" | head -1 | cut -d: -f2- | xargs || true)
        case "$(printf '%s' "$runas" | tr '[:upper:]' '[:lower:]')" in
          *system*) ;;
          "") ;;
          *) echo "⚠️  Läuft als '$runas' — also nur bei angemeldetem Nutzer."
             echo "   In einer Administrator-Konsole: agent-mesh service install" ;;
        esac
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
    linux) journalctl -u "$SVC_NAME.service" --no-pager -n "$n" 2>&1 || echo "Keine Logs" ;;
    *)     tail -n "$n" "$AGENT_MESH_HOME/watch.log" 2>/dev/null || echo "Keine Logs ($AGENT_MESH_HOME/watch.log)" ;;
  esac
}

svc_restart() {
  local os; os=$(os_name)
  case "$os" in
    linux) systemctl restart "$SVC_NAME.timer" && echo "✅ $SVC_NAME.timer neu gestartet" ;;
    macos)
      launchctl unload "$HOME/Library/LaunchAgents/$SVC_LABEL.plist" 2>/dev/null || true
      launchctl load "$HOME/Library/LaunchAgents/$SVC_LABEL.plist" 2>/dev/null && echo "✅ $SVC_LABEL neu geladen"
      ;;
    windows)
      schtasks //End //TN "$WIN_TASK" >/dev/null 2>&1 || true
      schtasks //Run //TN "$WIN_TASK" >/dev/null 2>&1 && echo "✅ '$WIN_TASK' angestossen"
      ;;
  esac
}

svc_uninstall() {
  local os; os=$(os_name)
  case "$os" in
    linux)
      systemctl stop "$SVC_NAME.timer" 2>/dev/null || true
      systemctl disable "$SVC_NAME.timer" 2>/dev/null || true
      rm -f "/etc/systemd/system/$SVC_NAME.timer" "/etc/systemd/system/$SVC_NAME.service"
      retire_legacy_unit
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
