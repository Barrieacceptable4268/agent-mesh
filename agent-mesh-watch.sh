#!/usr/bin/env bash
# agent-mesh-watch — Konvergenz: den Soll-Zustand herstellen, immer wieder.
#
# ── Warum das umgebaut wurde ───────────────────────────────────────────────
# Am 2026-08-22 ging ein Wartungssignal an sechs Agents. Vier zogen nach, zwei
# nicht: ihr watch-Prozess war am Abend stehengeblieben. Das Signal gilt 30
# Minuten und wirkt genau einmal — wer in diesem Fenster nicht lief, hatte das
# Release für immer verpasst. Am nächsten Morgen standen beide unverändert da,
# und niemand wäre darauf gekommen, ausser jemand hätte in die Tabelle gesehen.
#
# Ein Signal ist ein EREIGNIS. Ereignisse gehen verloren. Ein Soll-Zustand
# nicht: er gilt weiter, egal wie lange niemand hingesehen hat.
#
#   converge = EIN idempotenter Durchlauf, der herstellt, was gelten soll.
#
# Zweimal laufen lassen ändert nichts. Eine durchschlafene Nacht wird beim
# ersten Aufruf danach aufgeholt. Das Wartungssignal bleibt erhalten — es
# beschleunigt jetzt nur noch, statt die einzige Zustellung zu sein.
#
# Und der Vergleich läuft gegen die LAUFENDE Version, nicht gegen die im
# Quellklon: "geholt" und "installiert" sind zweierlei, und genau diese
# Verwechslung hat schon zweimal eine Flotte grün aussehen lassen, während der
# alte Stand lief.
#
# Usage:
#   agent-mesh converge                    ein Durchlauf
#   agent-mesh watch [interval-sekunden]   Dauerlauf, Default 60
#
# Für den Dauerbetrieb ist `agent-mesh service install` vorzuziehen: ein
# Dienst kommt nach Absturz und Neustart von selbst wieder, eine Schleife im
# Terminal nicht.

set -euo pipefail

# Beim Sourcen darf NICHTS laufen — nur beim Dispatch von converge/watch.

# Gemeinsame Umgebung für beide Kommandos.
_converge_env() {
  AGENT_MESH_HOME="${AGENT_MESH_HOME:-$HOME/.agent-mesh}"
  CONF="$AGENT_MESH_HOME/agent-mesh.conf"
  MEMORIES_DIR="$AGENT_MESH_HOME/memories"
  FRAMEWORK_DIR="$AGENT_MESH_HOME/framework"
  BIN="${AGENT_MESH_BIN:-$(dirname "$(readlink -f "$0")")/agent-mesh}"
  GH_ORG="${AGENT_MESH_GH_ORG:-moinsen-dev}"
  PUBLIC_REPO="${AGENT_MESH_PUBLIC_REPO:-agent-mesh}"
  LOG="$AGENT_MESH_HOME/watch.log"

  [ -f "$CONF" ] || { echo "❌ Nicht initialisiert — zuerst: agent-mesh init <name>" >&2; return 1; }
  [ -d "$MEMORIES_DIR/.git" ] || { echo "❌ Repo-Klon fehlt — zuerst: agent-mesh sync" >&2; return 1; }

  AGENT_NAME=$(grep "^AGENT_NAME=" "$CONF" | cut -d= -f2- || true)
  # SSH-Key-Option laden (falls gesetzt)
  local ssh_line
  ssh_line=$(grep "^GIT_SSH_COMMAND=" "$CONF" | cut -d= -f2- || true)
  [ -n "$ssh_line" ] && export GIT_SSH_COMMAND="$ssh_line"
  return 0
}

# ── Schritt 1: läuft hier die Soll-Version? ────────────────────────────────
# Massstab ist VERSION auf origin/main des öffentlichen Repos. Installiert
# wird davon nichts direkt — `update` holt das signierte Tag und prüft es.
# Hier wird nur entschieden, OB es etwas zu tun gibt.
#
# Der Netzabruf wird gedrosselt: eine Zeitmarke statt eines Zykluszählers,
# damit es keine Rolle spielt, ob converge aus einer Schleife, einem Timer
# oder von Hand kommt. Ein Zähler fängt nach jedem Neustart bei null an —
# deshalb hat ein frisch gestarteter watch bisher eine Stunde lang gar nicht
# nach Updates gesehen.
CONVERGE_VERSION_EVERY="${AGENT_MESH_VERSION_CHECK_EVERY:-900}"   # Sekunden

_desired_version() {
  local stamp="$AGENT_MESH_HOME/.desired-version"
  local age=999999 now; now=$(date -u +%s)
  if [ -f "$stamp" ]; then
    local mt
    # BSD und GNU stat sind nicht austauschbar — beide versuchen.
    mt=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null || echo 0)
    age=$((now - mt))
  fi
  if [ "$age" -lt "$CONVERGE_VERSION_EVERY" ] && [ -s "$stamp" ]; then
    cat "$stamp"; return 0
  fi
  # Ohne Klon gibt es nichts zu vergleichen — dann soll `update` klonen.
  [ -d "$FRAMEWORK_DIR/.git" ] || { echo ""; return 0; }
  local v
  v=$( (cd "$FRAMEWORK_DIR" && git fetch origin main --quiet 2>/dev/null; \
        git show origin/main:VERSION 2>/dev/null) || true )
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  if [ -n "$v" ]; then
    printf '%s' "$v" > "$stamp"
    echo "$v"
  else
    # Netz weg: die letzte bekannte Soll-Version gilt weiter. Ein Ausfall der
    # Verbindung darf keinen Agent zum Handeln bewegen.
    cat "$stamp" 2>/dev/null || echo ""
  fi
}

# Die Version, die WIRKLICH läuft. Das CLI-Modul trägt sie eingebettet; ist es
# (noch) nicht geladen, hilft der Quellklon als Näherung weiter.
_running_version() {
  if [ -n "${AGENT_MESH_VERSION:-}" ]; then
    echo "$AGENT_MESH_VERSION"
  else
    cat "$FRAMEWORK_DIR/VERSION" 2>/dev/null || echo "0.0.0"
  fi
}

# ── Wann darf wieder geholt werden? ───────────────────────────────────────
#
# Am 2026-08-24 meldete der macmini beim Aktualisieren HTTP 429: GitHub hatte
# genug. Was agent-mesh in dem Fall tat, stand in einer Zeile:
#
#     git fetch origin main --quiet 2>/dev/null
#
# Der Fehler ging nach /dev/null, das Ergebnis wurde als "nichts geändert"
# gedeutet, und sechzig Sekunden später wurde es wieder versucht. Sechs Agenten
# im Minutentakt gegen ein Rate-Limit halten das Limit am Leben — der Client
# war Teil des Problems, und nach aussen sah es aus wie Schweigen.
#
# EIN Mechanismus deckt drei Fälle ab, weil alle drei dieselbe Frage stellen:
# wann lohnt der nächste Abruf?
#
#   etwas geändert   → sofort wieder (Grundintervall). Es ist etwas los.
#   nichts geändert  → langsamer werden, bis zur Ruhe-Obergrenze. Wer nichts
#                      zu sagen hat, muss nicht jede Minute gefragt werden.
#   abgelehnt        → deutlich langsamer werden (exponentiell), bis zur
#                      Fehler-Obergrenze. Das ist der Unterschied zwischen
#                      einem höflichen und einem lästigen Client.
#
# Jeder Erfolg setzt die Bremse zurück.
FETCH_MIN="${AGENT_MESH_FETCH_MIN:-60}"          # Grundintervall
FETCH_IDLE_CAP="${AGENT_MESH_FETCH_IDLE_CAP:-300}"   # Ruhe: höchstens 5 Min
FETCH_FAIL_CAP="${AGENT_MESH_FETCH_FAIL_CAP:-1800}"  # Fehler: höchstens 30 Min

_fetch_state_file() { echo "$AGENT_MESH_HOME/.fetch-state"; }

# Gibt "naechster_zeitpunkt intervall" aus; fehlt die Datei, ist jetzt fällig.
_fetch_state() {
  local f; f=$(_fetch_state_file)
  if [ -s "$f" ]; then cat "$f"; else echo "0 $FETCH_MIN"; fi
}

_fetch_due() {
  local now next; now=$(date -u +%s)
  next=$(_fetch_state | awk '{print $1}')
  case "$next" in ''|*[!0-9]*) return 0 ;; esac
  [ "$now" -ge "$next" ]
}

# _fetch_record <changed|idle|failed>
_fetch_record() {
  local outcome="$1" now iv
  now=$(date -u +%s)
  iv=$(_fetch_state | awk '{print $2}')
  case "$iv" in ''|*[!0-9]*) iv="$FETCH_MIN" ;; esac
  case "$outcome" in
    changed) iv="$FETCH_MIN" ;;
    idle)    iv=$(( iv * 2 )); [ "$iv" -gt "$FETCH_IDLE_CAP" ] && iv="$FETCH_IDLE_CAP" ;;
    failed)  iv=$(( iv * 2 )); [ "$iv" -gt "$FETCH_FAIL_CAP" ] && iv="$FETCH_FAIL_CAP" ;;
  esac
  [ "$iv" -lt "$FETCH_MIN" ] && iv="$FETCH_MIN"
  printf '%s %s\n' "$(( now + iv ))" "$iv" > "$(_fetch_state_file)" 2>/dev/null || true
}

# Warum ist dieser Agent gerade still? Wer es nicht aufschreibt, kann es
# hinterher niemandem sagen — und genau das war der Zustand des macmini:
# lief, konnte nicht veröffentlichen, sah von aussen aus wie ausgeschaltet.
_note_failure() {   # _note_failure <text>
  local f="$AGENT_MESH_HOME/.last-error"
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$f" 2>/dev/null || true
}
_clear_failure() { rm -f "$AGENT_MESH_HOME/.last-error" 2>/dev/null || true; }

# Aus der Fehlerausgabe von git das herauslesen, womit ein Mensch etwas
# anfangen kann. "429" allein schickt ihn suchen.
_diagnose_git() {   # _diagnose_git <stderr-text>
  case "$1" in
    *429*|*"rate limit"*|*"rate-limited"*|*"Zu viele"*)
      echo "GitHub drosselt (HTTP 429) — Abrufe werden vorerst seltener" ;;
    *"Could not resolve host"*|*"Konnte den Host"*|*"Temporary failure in name resolution"*)
      echo "Kein Netz (DNS)" ;;
    *"Permission denied"*|*"Authentication failed"*|*"could not read Username"*)
      echo "Zugang abgelehnt — agent-mesh connect" ;;
    *"timed out"*|*"Timeout"*)
      echo "Zeitüberschreitung zu GitHub" ;;
    "") echo "git fetch gescheitert (ohne Meldung)" ;;
    *)  echo "$(printf '%s' "$1" | tr '\n' ' ' | cut -c1-90)" ;;
  esac
}

# ── Ein Durchlauf ──────────────────────────────────────────────────────────
cmd_converge() {
  local quiet=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) quiet=1 ;;
      --once)  ;;   # Default; nur der Deutlichkeit halber erlaubt
      *) echo "❌ converge: unbekannte Option '$1' (agent-mesh converge --help)" >&2; return 2 ;;
    esac
    shift
  done
  _converge_env || return 1

  local changed=0 failed=0

  # 1. Soll-Version herstellen
  # Nur nachziehen, wenn die laufende Version ÄLTER ist — nicht bei jeder
  # Abweichung. Sonst versucht eine Maschine, die dem Release voraus ist (die
  # des Maintainers, oder eine mitten in der Vorbereitung), sich im Minutentakt
  # herunterzustufen, wird jedes Mal vom Downgrade-Schutz abgewiesen und
  # meldet dauerhaft rot.
  local want have newer=1
  want=$(_desired_version); have=$(_running_version)
  if type version_lt >/dev/null 2>&1; then
    version_lt "$have" "$want" || newer=0
  else
    [ "$want" != "$have" ] || newer=0
  fi
  if [ -n "$want" ] && [ "$newer" = "1" ]; then
    changed=1
    echo "⬆️  Version v$have → v$want — aktualisiere…"
    if "$BIN" update >> "$LOG" 2>&1; then
      # Nicht die Handlung melden, sondern das Ergebnis: `update` kann die
      # Signaturprüfung bestehen und trotzdem an fehlenden Schreibrechten
      # scheitern. Was zählt, ist, was danach läuft.
      local now_v; now_v=$("$BIN" --version 2>/dev/null | head -1 | awk '{print $2}')
      if [ "$now_v" = "$want" ]; then
        echo "✅ jetzt auf v$want"
      else
        echo "❌ Update lief, aber es läuft weiter v${now_v:-?} — Log: $LOG"
        failed=1
      fi
    else
      echo "❌ Update fehlgeschlagen — Log: $LOG"
      failed=1
    fi
  fi

  # 2. Wartungssignale (Beschleuniger; Schritt 1 wirkt auch ohne sie)
  "$BIN" maintenance-run >> "$LOG" 2>&1 || failed=1

  # 3. Repo-Änderungen übernehmen — aber nur, wenn es an der Zeit ist.
  if _fetch_due; then
    local ferr frc=0
    ferr=$( (cd "$MEMORIES_DIR" && git fetch origin main --quiet 2>&1 >/dev/null) ) || frc=1
    if [ "$frc" != "0" ]; then
      local why; why=$(_diagnose_git "$ferr")
      _fetch_record failed
      _note_failure "$why"
      echo "⚠️  Abgleich nicht möglich: $why"
      echo "   Nächster Versuch frühestens in $(( $(_fetch_state | awk '{print $2}') / 60 )) Min."
      failed=1
    else
      _clear_failure
      local behind
      behind=$(cd "$MEMORIES_DIR" && git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
      if [ "${behind:-0}" -gt 0 ]; then
        changed=1
        _fetch_record changed
        echo "⬆️  $behind neue Commit(s) — synce…"
        "$BIN" sync >> "$LOG" 2>&1 || { echo "⚠️  sync meldete Fehler — Log: $LOG"; failed=1; }
        local inbox
        inbox=$("$BIN" inbox 2>/dev/null | grep -c "──" || true)
        [ "${inbox:-0}" -gt 0 ] && echo "📬 $inbox Nachricht(en) (agent-mesh inbox)"
        "$BIN" respond >> "$LOG" 2>&1 || { echo "⚠️  Auto-Respond meldete Fehler — Log: $LOG"; failed=1; }
      else
        _fetch_record idle
      fi
    fi
  fi

  # 4. Relay-Warteschlange
  "$BIN" peer-recv >> "$LOG" 2>&1 || true

  # Auch OHNE Änderung muss das Lebenszeichen frisch werden: ein alter Bericht
  # ist in der Flottenübersicht nicht von einem toten Agenten zu unterscheiden.
  #
  # Dafür läuft seit v1.34.0 kein voller sync mehr, sondern nur die
  # Veröffentlichung des Berichts auf die eigene Referenz — ein Push, der main
  # nicht berührt und deshalb bei niemandem etwas auslöst. Vorher stiess ein
  # stündlicher Herzschlag einen kompletten Abgleich an, inklusive Export,
  # Import und Commit auf main.
  local cache="$AGENT_MESH_HOME/.last-report.json"
  if [ "$changed" = "0" ]; then
    local rage=999999 mt now
    now=$(date -u +%s)
    if [ -f "$cache" ]; then
      mt=$(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0)
      rage=$((now - mt))
    fi
    if [ "$rage" -gt "${AGENT_MESH_HEARTBEAT:-3600}" ]; then
      "$BIN" report --publish >> "$LOG" 2>&1 || failed=1
    fi
  fi

  # Ein Lebenszeichen bei JEDEM Lauf — auch wenn nichts zu tun war. Seit der
  # Dienst ein Intervall ist, gibt es keinen Prozess mehr, an dem man sehen
  # könnte, ob dieser Agent noch zuhört. Ohne diese Marke hat `doctor` genau
  # das getan, was dieses Projekt sonst bekämpft: eine wahr klingende
  # Falschaussage — "kein watch-Prozess" über eine Maschine, die im
  # Minutentakt konvergiert.
  date -u +%s > "$AGENT_MESH_HOME/.last-converge" 2>/dev/null || true

  [ "$changed" = "0" ] && [ "$quiet" = "0" ] && echo "✅ Soll-Zustand — nichts zu tun (v$have)"
  return "$failed"
}

# ── Dauerlauf ──────────────────────────────────────────────────────────────
cmd_watch() {
  local interval="${1:-60}"
  case "$interval" in
    *[!0-9]*|'') echo "❌ Intervall muss eine Zahl sein (Sekunden)" >&2; exit 1 ;;
  esac
  _converge_env || exit 1

  log() { echo "[$(date -u +%H:%M:%S)] $*"; }
  log "🔄 agent-mesh watch gestartet (Agent: $AGENT_NAME, Intervall: ${interval}s)"
  log "   Versionsprüfung höchstens alle ${CONVERGE_VERSION_EVERY}s — und sofort beim Start."

  while true; do
    # Jede Runde ist ein vollständiger, in sich abgeschlossener Abgleich.
    # Fällt eine aus, ist die nächste dadurch nicht weniger vollständig.
    # Das `|| true` ist nicht kosmetisch: unter `set -e` würde ein converge,
    # das eine 1 zurückgibt, die Schleife beenden — also genau das
    # stille Absterben des Daemons, dessentwegen dieser Umbau stattfindet.
    { cmd_converge --quiet 2>&1 || true; } | while IFS= read -r line; do log "$line"; done
    sleep "$interval"
  done
}
