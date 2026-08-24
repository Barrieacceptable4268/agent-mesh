#!/usr/bin/env bash
# agent-mesh-doctor — Preflight-Checks für das Agent-Mesh (Issue #2).
#
# Prüft, ob alle Abhängigkeiten für verschlüsselte Kommunikation vorhanden
# und nutzbar sind, BEVOR send/vault fehlschlagen. Gibt klare,
# plattformspezifische Reparatur-Hinweise statt kryptischer Fehler.
#
#   agent-mesh doctor            # alle Checks
#   agent-mesh doctor --vault    # nur Vault/Encryption-Checks
#   agent-mesh doctor --net      # nur GitHub/Repo-Checks
#   agent-mesh doctor --security # Sicherheitsstand nach v1.13.0 prüfen

set -euo pipefail

# ── Sicherheits-Check (v1.13.0, Audit 2026-08-22) ──
# Beantwortet auf JEDEM Agent die Frage "ist die Migration bei mir angekommen?"
# — und macht dabei einen ECHTEN age-Roundtrip statt nur Dateien zu zählen.
security_checks() {
  local ok=0 fail=0
  pass() { ok=$((ok+1)); echo "  ✅ $*"; }
  bad()  { fail=$((fail+1)); echo "  ❌ $*"; }
  note() { echo "     $*"; }

  echo "🔐 Sicherheitsstand (Agent: $AGENT_NAME)"
  echo ""
  echo "── Relay-Auth (Befund #4) ──"

  if grep -q "^AGENT_MESH_RELAY_TOKEN=" "$CONF" 2>/dev/null; then
    bad "Altes AGENT_MESH_RELAY_TOKEN steht noch in der Konfiguration"
    note "Es hat keine Funktion mehr, gehört aber entfernt:"
    note "  sed -i.bak '/^AGENT_MESH_RELAY_TOKEN=/d' $CONF"
  else
    pass "Kein geteiltes Relay-Token mehr in der Konfiguration"
  fi

  if [ -f "$AGE_KEY_FILE" ]; then
    pass "Eigener age-Key vorhanden: $AGE_KEY_FILE"
    local perm
    # BSD und GNU stat sind hier nicht austauschbar, und ein Fallback per ||
    # reicht NICHT: GNU beendet sich zwar mit 1, schreibt vorher aber
    # Dateisystem-Infos nach stdout — die Kommando-Substitution sammelt beides
    # ein, und der Vergleich scheitert an korrekten Rechten. Also nach
    # Plattform entscheiden statt zu probieren. (Fund vom ax41-Agenten.)
    case "$(uname -s 2>/dev/null)" in
      Darwin|*BSD*) perm=$(stat -f "%Lp" "$AGE_KEY_FILE" 2>/dev/null || echo "?") ;;
      *)            perm=$(stat -c "%a" "$AGE_KEY_FILE" 2>/dev/null || echo "?") ;;
    esac
    if [ "$perm" = "600" ] || [ "$perm" = "400" ]; then
      pass "Key-Dateirechte: $perm"
    else
      bad "Key-Dateirechte sind $perm — sollten 600 sein"
      note "  chmod 600 $AGE_KEY_FILE"
    fi
  else
    bad "Eigener age-Key fehlt: $AGE_KEY_FILE — Relay-Auth unmöglich"
  fi

  # Echter Roundtrip: verschlüsseln an den eigenen registrierten Public-Key,
  # dann mit dem privaten Key wieder öffnen. Genau das macht der Relay-Login.
  local mypub="$MEMORIES_DIR/vault/keys/$AGENT_NAME.age.pub"
  if [ -f "$mypub" ] && [ -f "$AGE_KEY_FILE" ] && command -v "$AGE_BIN" >/dev/null 2>&1; then
    local probe back
    probe="challenge-probe-$$"
    back=$(printf '%s' "$probe" | "$AGE_BIN" --encrypt --armor --recipient "$(cat "$mypub")" 2>/dev/null \
           | "$AGE_BIN" --decrypt --identity "$AGE_KEY_FILE" 2>/dev/null || true)
    if [ "$back" = "$probe" ]; then
      pass "age-Challenge-Response funktioniert (echter Roundtrip)"
    else
      bad "age-Roundtrip fehlgeschlagen — der Relay-Login würde scheitern"
      note "Passt der registrierte Public-Key noch zum privaten Key?"
      note "  age-keygen -y $AGE_KEY_FILE   ← muss gleich sein wie"
      note "  cat $mypub"
    fi
  else
    bad "Roundtrip nicht prüfbar (Public-Key registriert? age installiert?)"
  fi

  echo ""
  echo "── Key-Pinning (Befund #6) ──"
  local npins nkeys
  npins=$(grep -c "^PIN_" "$CONF" 2>/dev/null || echo 0)
  nkeys=0
  for _k in "$MEMORIES_DIR"/vault/keys/*.pub; do [ -f "$_k" ] && nkeys=$((nkeys+1)); done
  pass "$npins von $nkeys bekannten Agents gepinnt (wächst beim Benutzen)"
  local drift=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local a="${line%%=*}"; a="${a#PIN_}"
    local k="${line#*=}"
    local f="$MEMORIES_DIR/vault/keys/$a.age.pub"
    if [ -f "$f" ] && [ "$(cat "$f")" != "$k" ]; then
      bad "KEY-ABWEICHUNG bei '$a' — gepinnter Key ≠ Registry-Key"
      note "Erst über einen zweiten Kanal prüfen, dann: agent-mesh vault repin $a"
      drift=1
    fi
  done < <(grep "^PIN_" "$CONF" 2>/dev/null || true)
  [ "$drift" = "0" ] && pass "Keine Key-Abweichungen"

  echo ""
  echo "── Nachrichten-Signaturen (Befund 10) ──"
  local skf="$AGENT_MESH_HOME/keys/$AGENT_NAME.ssh"
  if [ -f "$skf" ]; then
    pass "Eigener Signaturschlüssel vorhanden"
    local reg="$MEMORIES_DIR/vault/keys/$AGENT_NAME.ssh.pub"
    if [ -f "$reg" ] && [ "$(cat "$reg")" = "$(cat "$skf.pub" 2>/dev/null)" ]; then
      pass "Signatur-Public-Key ist aktuell in der Registry"
    else
      bad "Signatur-Public-Key fehlt oder weicht ab — andere können dich nicht prüfen"
      note "  agent-mesh sync"
    fi
    # Echter Roundtrip: signieren und selbst verifizieren
    local tf; tf=$(mktemp); echo "probe-$$" > "$tf"
    if sig=$(sign_payload "$tf" 2>/dev/null) && [ -n "$sig" ]; then
      local sf; sf=$(mktemp); printf '%s' "$sig" > "$sf"
      if verify_payload "$tf" "$sf" "$AGENT_NAME" 2>/dev/null; then
        pass "Signieren und Prüfen funktioniert (echter Roundtrip)"
      else
        bad "Eigene Signatur ist nicht verifizierbar"
      fi
      rm -f "$sf"
    else
      bad "Signieren fehlgeschlagen (ssh-keygen vorhanden?)"
    fi
    rm -f "$tf"
  else
    bad "Kein Signaturschlüssel — deine Nachrichten gelten als unbelegt"
    note "  agent-mesh sync   (legt ihn an und veröffentlicht ihn)"
  fi
  # ls auf ein leeres Glob scheitert — unter "set -e" reisst das den ganzen
  # Bericht ab, ausgerechnet bei Agents, die noch nichts veroeffentlicht haben.
  local nsig=0 nage=0 k
  for k in "$MEMORIES_DIR"/vault/keys/*.ssh.pub; do [ -f "$k" ] && nsig=$((nsig+1)); done
  for k in "$MEMORIES_DIR"/vault/keys/*.age.pub; do [ -f "$k" ] && nage=$((nage+1)); done
  if [ "${nsig:-0}" -lt "${nage:-0}" ]; then
    bad "$nsig von $nage Agents haben einen Signaturschlüssel veröffentlicht"
    note "Nachrichten der übrigen erscheinen als UNSIGNIERT, bis sie einmal syncen."
  else
    pass "Alle $nage bekannten Agents haben einen Signaturschlüssel"
  fi

  echo ""
  echo "── Update-Signaturen (Befund 8) ──"
  local sf="${AGENT_MESH_SIGNERS_FILE:-$AGENT_MESH_HOME/trusted_signers}"
  if [ -s "$sf" ] && [ "$(grep -cvE '^[[:space:]]*(#|$)' "$sf")" -gt 0 ]; then
    pass "Vertrauensbasis hinterlegt ($(grep -cvE '^[[:space:]]*(#|$)' "$sf") Schlüssel)"
    local rv tag
    rv=$(cat "$FRAMEWORK_DIR/VERSION" 2>/dev/null || echo "")
    tag="v$rv"
    # Tag zuerst HOLEN. Ein "git pull origin main" bringt Tags nicht zuverlässig
    # mit, und ohne diesen Schritt meldete der doctor fehlende Signaturen, wo
    # nur das lokale Abbild unvollständig war — inklusive einer Schuldzuweisung
    # an den Release-Prozess. (Fund vom hermes-hetzner-Agenten, der genau
    # deshalb meldete, die Releases seien ungetaggt.)
    (cd "$FRAMEWORK_DIR" && git fetch --quiet origin "refs/tags/$tag:refs/tags/$tag" --force 2>/dev/null) || true
    if [ -n "$rv" ] && (cd "$FRAMEWORK_DIR" && git rev-parse "$tag" >/dev/null 2>&1); then
      if (cd "$FRAMEWORK_DIR" && git -c gpg.format=ssh \
            -c gpg.ssh.allowedSignersFile="$sf" verify-tag "$tag" >/dev/null 2>&1); then
        pass "Aktuelles Release $tag ist gültig signiert"
      else
        bad "Release $tag lässt sich NICHT verifizieren"
        note "Der nächste 'agent-mesh update' wird verweigern. Prüfen:"
        note "  agent-mesh trust --show"
      fi
    else
      # Zwischen "gibt es nicht" und "haben wir nur nicht" unterscheiden —
      # das sind zwei völlig verschiedene Aufgaben für zwei verschiedene Leute.
      if (cd "$FRAMEWORK_DIR" && git ls-remote --tags origin "refs/tags/$tag" 2>/dev/null | grep . >/dev/null); then
        bad "Tag '$tag' liegt auf dem Remote, fehlt aber lokal — Klon unvollständig"
        note "  cd $FRAMEWORK_DIR && git fetch --tags origin"
      else
        bad "Es gibt kein Tag '$tag' — dieses Release wurde nicht getaggt"
        note "Das ist eine Maintainer-Aufgabe, nicht deine: docs/RELEASING.md"
      fi
    fi
  else
    bad "Keine Vertrauensbasis für Release-Signaturen hinterlegt"
    note "Ohne sie verweigert jedes Update: agent-mesh trust"
  fi

  echo ""
  echo "── Installationsorte ──"
  # Ist /usr/local/bin nicht schreibbar (auf macOS als normaler Nutzer der
  # Normalfall), installiert der Updater nach ~/.local/bin — und eine ältere
  # Kopie in /usr/local/bin bleibt liegen. Ein Dienst, der dorthin zeigt,
  # startet dann weiter den alten Stand, während "update" Erfolg meldet.
  local found=0 stale=0 d probe fw
  fw="$FRAMEWORK_DIR"
  for d in /usr/local/bin "$HOME/.local/bin" /opt/homebrew/bin /usr/bin; do
    [ -f "$d/agent-mesh" ] || continue
    found=$((found+1))
    local diffs=0 f base difflist=""
    for f in "$fw"/agent-mesh "$fw"/agent-mesh-*.sh "$fw"/agent-mesh-*.py "$fw"/agent-mesh-*.js; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      [ -f "$d/$base" ] || continue
      if ! cmp -s "$f" "$d/$base"; then diffs=$((diffs+1)); difflist="$difflist $base"; fi
    done
    if [ "$diffs" -eq 0 ]; then
      pass "$d — aktuell"
    else
      # "1 Datei weicht ab" ist keine handlungsfähige Aussage — welche?
      bad "$(printf '%s — %s Datei(en) weichen ab: %.70s' "$d" "$diffs" "$(echo "$difflist" | sed 's/^ //')")"
      stale=$((stale+1))
    fi
  done
  if [ "$found" -eq 0 ]; then
    bad "Keine Installation gefunden — läuft agent-mesh aus dem Klon?"
  elif [ "$found" -gt 1 ]; then
    bad "$found parallele Installationen — Dienste könnten auf die falsche zeigen"
    note "Welche greift: $(command -v agent-mesh 2>/dev/null || echo '?')"
    note "Überzählige entfernen oder den Dienst auf die aktuelle umbiegen."
  fi
  if [ "$stale" -gt 0 ]; then
    note "Veraltete Kopie aktualisieren (ggf. mit sudo):"
    note "  sudo cp \"$fw\"/agent-mesh \"$fw\"/agent-mesh-*.sh \"$fw\"/agent-mesh-*.py \"$fw\"/agent-mesh-*.js <ziel>/"
  fi

  echo ""
  echo "── Framework-Stand ──"
  local v; v=$(cat "$FRAMEWORK_DIR/VERSION" 2>/dev/null || echo "?")
  case "$v" in
    1.1[3-9].*|1.[2-9][0-9].*|[2-9].*) pass "Framework v$v enthält die Sicherheits-Fixes" ;;
    *) bad "Framework v$v ist älter als v1.13.0 — 'agent-mesh update' ausführen" ;;
  esac

  echo ""
  echo "── Lebenszeichen ──"
  # Bis v1.27.0 wurde nur ERHOBEN, ob ein watch-Prozess läuft; ein Befund war
  # es nie. Am 2026-08-22 haben genau deshalb zwei Agents ein Release über
  # Nacht verpasst: kein Watcher, kein Update, keine Nachricht — und nichts,
  # das gesagt hätte, dass dort niemand mehr zuhört.
  if [ "$(converge_liveness "${AGENT_MESH_HOME:-$HOME/.agent-mesh}")" = "ja" ]; then
    pass "Konvergenz läuft — dieser Agent bekommt Updates und Nachrichten mit"
  else
    bad "Seit über $((CONVERGE_STALE_AFTER / 60)) Minuten keine Konvergenz — dieser Agent hört nicht zu"
    note "Ein stiller Agent verpasst Updates, Nachrichten und Wartungssignale."
    note "Einrichten (ein Intervall, kein Prozess, der sterben kann):"
    note "  agent-mesh service install && agent-mesh service status"
  fi
  # Läuft er, kommt aber nicht durch? Von aussen sieht beides gleich aus —
  # der macmini lief am 2026-08-24 und wurde von GitHub abgewiesen, und die
  # Flotte hat ihn 35 Stunden lang als ausgeschaltet geführt.
  local le="${AGENT_MESH_HOME:-$HOME/.agent-mesh}/.last-error"
  if [ -f "$le" ]; then
    bad "Letzter Abgleich gescheitert: $(cut -f2- "$le" 2>/dev/null | head -1)"
    note "seit $(cut -f1 "$le" 2>/dev/null | head -1)"
    note "Der Agent läuft, kommt aber nicht durch — für die Flotte sieht das"
    note "aus wie Schweigen. Die Abrufe werden bereits gedrosselt."
  fi

  echo ""
  if [ "$fail" -eq 0 ]; then
    echo "✅ $ok Prüfungen bestanden — keine offenen Sicherheitsbefunde."
  else
    echo "⚠️  $ok bestanden, $fail offen — siehe die Hinweise oben."
    echo "   Vollständige Anleitung: $FRAMEWORK_DIR/MIGRATIONS.md"
  fi
  return 0
}

# ── agent-mesh report ──────────────────────────────────────────────────────
# Ein kompakter, kopierbarer Zustandsbericht. Zweck: nachprüfbare Tatsachen
# statt einer wohlwollenden Zusammenfassung. Beim ersten Flotten-Rollout kamen
# von vier Agents vier Prosa-Berichte, von denen mehrere Dinge als erledigt
# meldeten, die es nicht waren — nicht aus Nachlässigkeit, sondern weil die
# Werkzeuge meldeten, was sie TATEN, nicht was dabei herauskam.
#
# Deshalb hier ausschliesslich Beobachtungen aus dem Dateisystem und aus git.
# Läuft bewusst auch auf einer Maschine, auf der nichts eingerichtet ist —
# genau dann ist der Bericht am wertvollsten.
# Fakten einmal erheben, zweimal darstellen: einmal für Menschen, einmal als
# JSON für die Flotten-Übersicht. Getrennte Erhebungen wären zwei Wahrheiten.
# Setzt R_* Variablen.
report_facts() {
  local home="${AGENT_MESH_HOME:-$HOME/.agent-mesh}"
  local conf="$home/agent-mesh.conf"
  local fw="$home/framework"

  R_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  R_HOST=$(hostname 2>/dev/null || echo "?")
  R_OS=$(uname -sr 2>/dev/null || echo "?")
  R_AGENT=""; R_VERSION=""; R_COMMIT=""; R_REMOTE=""; R_INSTALLS=""
  R_ONPATH=""; R_TRUST=""; R_RELEASE=""; R_KEYS=""; R_TOKEN="nein"
  R_WATCHER="nein"; R_OK=0; R_BAD=0; R_ISSUES=""; R_COMPONENTS=""; R_LASTERR=""

  [ -f "$conf" ] && R_AGENT=$(grep "^AGENT_NAME=" "$conf" 2>/dev/null | cut -d= -f2- | head -1)

  if [ -d "$fw/.git" ]; then
    R_VERSION=$(cat "$fw/VERSION" 2>/dev/null || echo "?")
    # NICHT mit `cut -c` kürzen: ob das Zeichen oder Bytes zählt, hängt am
    # Locale. Interaktiv (LANG=…UTF-8) sind es Zeichen, unter launchd/systemd
    # ohne LANG sind es Bytes — und dann wird ein mehrbyte Zeichen mitten
    # durchgeschnitten. Am 2026-08-24 lag der Gedankenstrich einer
    # Commit-Meldung genau auf Position 58; das ergab ungültiges UTF-8, der
    # Bericht wurde zu Recht als ungültig verworfen, und weil ALLE Agenten
    # denselben Framework-Commit melden, schwieg die ganze Flotte vier Stunden.
    # Gekürzt wird jetzt dort, wo die Kodierung bekannt ist: in Python.
    R_COMMIT=$(git -C "$fw" log -1 --format='%h %s' 2>/dev/null | head -1)
    R_REMOTE=$(git -C "$fw" show origin/main:VERSION 2>/dev/null || echo "?")
  fi

  local d base f diffs total
  for d in /usr/local/bin "$HOME/.local/bin" /opt/homebrew/bin; do
    [ -f "$d/agent-mesh" ] || continue
    diffs=0; total=0
    if [ -d "$fw" ]; then
      for f in "$fw"/agent-mesh "$fw"/agent-mesh-*.sh "$fw"/agent-mesh-*.py "$fw"/agent-mesh-*.js; do
        [ -f "$f" ] || continue
        base=$(basename "$f"); total=$((total+1))
        [ -f "$d/$base" ] && cmp -s "$f" "$d/$base" || diffs=$((diffs+1))
      done
    fi
    R_INSTALLS="$R_INSTALLS$d:$diffs/$total "
  done
  R_ONPATH=$(command -v agent-mesh 2>/dev/null || echo "")

  local sf="${AGENT_MESH_SIGNERS_FILE:-$home/trusted_signers}"
  if [ -s "$sf" ] && [ "$(grep -cvE '^[[:space:]]*(#|$)' "$sf" 2>/dev/null || echo 0)" -gt 0 ]; then
    R_TRUST=$(awk '!/^[[:space:]]*(#|$)/{print $1}' "$sf" 2>/dev/null | tr '\n' ' ')
  fi

  R_RELEASE="unbekannt"
  if [ -d "$fw/.git" ] && [ -n "$R_VERSION" ] && [ "$R_VERSION" != "?" ]; then
    (cd "$fw" && git fetch --quiet origin "refs/tags/v$R_VERSION:refs/tags/v$R_VERSION" --force 2>/dev/null) || true
    if (cd "$fw" && git rev-parse "v$R_VERSION" >/dev/null 2>&1); then
      if (cd "$fw" && git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$sf" \
            verify-tag "v$R_VERSION" >/dev/null 2>&1); then R_RELEASE="signiert"
      else R_RELEASE="nicht verifizierbar"; fi
    else R_RELEASE="kein Tag"; fi
  fi

  if [ -n "$R_AGENT" ]; then
    R_KEYS=""
    [ -f "$home/keys/$R_AGENT.age" ] && R_KEYS="age" || R_KEYS="age-fehlt"
    if [ -f "$home/keys/$R_AGENT.ssh" ]; then
      if [ -f "$home/memories/vault/keys/$R_AGENT.ssh.pub" ] \
         && cmp -s "$home/keys/$R_AGENT.ssh.pub" "$home/memories/vault/keys/$R_AGENT.ssh.pub"; then
        R_KEYS="$R_KEYS,sign-publiziert"
      else R_KEYS="$R_KEYS,sign-unpubliziert"; fi
    else R_KEYS="$R_KEYS,sign-fehlt"; fi
  fi

  [ -f "$conf" ] && grep "^AGENT_MESH_RELAY_TOKEN=" "$conf" >/dev/null 2>&1 && R_TOKEN="ja"
  # Zuhören heisst nicht mehr "ein Prozess läuft", sondern "es wurde vor
  # Kurzem konvergiert" — der Dienst ist seit v1.31.0 ein Intervall.
  R_WATCHER=$(converge_liveness "$home")
  R_COMPONENTS=$(running_components)
  # Warum war der letzte Abgleich nicht möglich? Steht nur da, wenn er es
  # nicht war — converge räumt die Datei bei jedem Erfolg weg.
  [ -f "$home/.last-error" ] && R_LASTERR=$(cut -f2- "$home/.last-error" 2>/dev/null | head -1)

  if [ -f "$conf" ]; then
    local out
    out=$(cmd_doctor --security 2>&1 || true)
    R_OK=$(printf '%s\n' "$out" | grep -c "✅" || true)
    R_BAD=$(printf '%s\n' "$out" | grep -c "❌" || true)
    R_ISSUES=$(printf '%s\n' "$out" | grep "❌" | sed 's/^ *//' | head -8 || true)
  fi
}

# Welche agent-mesh-Komponenten laufen auf DIESER Maschine?
#
# Entstanden aus einer Frage, die sich von aussen nicht beantworten liess:
# `agent-mesh-relay.py`, `-webhook.py` und `-dashboard.js` werden auf jede
# Maschine installiert, aber von der CLI nie aufgerufen — sie sind eigene
# Dienste. Ob sie irgendwo laufen, wusste niemand, und "wahrscheinlich nicht"
# ist keine Grundlage, um 800 Zeilen zu löschen.
#
# Ein Verbund, der nicht sagen kann, was in ihm läuft, kann nicht aufgeräumt
# werden. Also sagt er es jetzt.
running_components() {
  local found=""
  _rc_seen() { case " $found " in *" $1 "*) return 0;; *) return 1;; esac; }
  _rc_add()  { _rc_seen "$1" || found="$found $1"; }

  # Prozesse — funktioniert überall, auch ohne systemd.
  pgrep -f "[a]gent-mesh-relay.py"     >/dev/null 2>&1 && _rc_add relay
  pgrep -f "[a]gent-mesh-webhook.py"   >/dev/null 2>&1 && _rc_add webhook
  pgrep -f "[a]gent-mesh-dashboard.js" >/dev/null 2>&1 && _rc_add dashboard
  pgrep -f "[a]gent-mesh watch"        >/dev/null 2>&1 && _rc_add watch-alt

  # Dienste, die eingerichtet sind — auch wenn gerade kein Prozess läuft.
  if command -v systemctl >/dev/null 2>&1; then
    local u
    for u in agent-mesh-relay agent-mesh-webhook agent-mesh-dashboard; do
      systemctl is-enabled "$u" >/dev/null 2>&1 && _rc_add "${u#agent-mesh-}"
    done
    systemctl is-enabled agent-mesh-converge.timer >/dev/null 2>&1 && _rc_add converge-timer
    systemctl is-enabled agent-mesh-watch >/dev/null 2>&1 && _rc_add watch-alt
  fi
  if command -v launchctl >/dev/null 2>&1; then
    # Der Label ist derselbe geblieben, damit `launchctl load` die alte
    # Definition ERSETZT. Genau deshalb sagt "geladen" nichts darüber, WAS
    # geladen ist — erst StartInterval unterscheidet das Intervall vom alten
    # Dauerprozess. Ohne diese Prüfung meldete der macmini gleichzeitig
    # "converge-timer" und "seit 15 Minuten keine Konvergenz"; eines von
    # beidem war erfunden.
    if launchctl list 2>/dev/null | grep "dev.moinsen.agentmesh.watch" >/dev/null; then
      if grep -q "StartInterval" "$HOME/Library/LaunchAgents/dev.moinsen.agentmesh.watch.plist" 2>/dev/null; then
        _rc_add converge-timer
      else
        _rc_add watch-alt
      fi
    fi
  fi

  printf '%s' "${found# }"
}

# Wann hat dieser Agent zuletzt konvergiert? "ja" / "nein".
# Ein Dauerprozess zählt weiter mit — es gibt Maschinen, auf denen noch
# `agent-mesh watch` im Vordergrund läuft, und die hören sehr wohl zu.
CONVERGE_STALE_AFTER="${AGENT_MESH_CONVERGE_STALE:-900}"   # Sekunden
converge_liveness() {
  local home="${1:-$AGENT_MESH_HOME}" mark="${1:-$AGENT_MESH_HOME}/.last-converge"
  if [ -f "$mark" ]; then
    local then_s now_s
    then_s=$(cat "$mark" 2>/dev/null || echo 0)
    now_s=$(date -u +%s)
    case "$then_s" in
      ''|*[!0-9]*) ;;
      *) [ "$((now_s - then_s))" -lt "$CONVERGE_STALE_AFTER" ] && { echo "ja"; return 0; } ;;
    esac
  fi
  pgrep -f "[a]gent-mesh watch" >/dev/null 2>&1 && { echo "ja"; return 0; }
  echo "nein"
}

# ── agent-mesh doctor --fix ────────────────────────────────────────────────
# AUSSCHLIESSLICH Reparaturen, die nachweislich nichts kaputt machen können:
# eigene Schlüsselrechte verschärfen und eine funktionslose Konfigurationszeile
# entfernen. Alles, was Urteilsvermögen braucht — ein Schlüsselwechsel, das
# Überschreiben einer Installation, ein Dienst-Neustart — bleibt bewusst
# draussen und wird nur benannt. Diese Trennung ist der Grund, warum --fix auch
# per Wartungs-Broadcast laufen darf.
doctor_fix() {
  local fixed=0 f
  echo "🔧 Sichere Reparaturen"

  # a) Rechte auf eigenen privaten Schlüsseln
  for f in "$AGENT_MESH_HOME/keys/"*.age "$AGENT_MESH_HOME/keys/"*.ssh; do
    [ -f "$f" ] || continue
    local perm
    case "$(uname -s 2>/dev/null)" in
      Darwin|*BSD*) perm=$(stat -f "%Lp" "$f" 2>/dev/null || echo "?") ;;
      *)            perm=$(stat -c "%a" "$f" 2>/dev/null || echo "?") ;;
    esac
    if [ "$perm" != "600" ] && [ "$perm" != "400" ]; then
      if chmod 600 "$f" 2>/dev/null; then
        echo "  ✓ $(basename "$f"): $perm → 600"
        fixed=$((fixed+1))
      else
        echo "  ❌ $(basename "$f"): chmod fehlgeschlagen"
      fi
    fi
  done

  # b) Funktionsloses Relay-Token aus der Konfiguration
  if grep "^AGENT_MESH_RELAY_TOKEN=" "$CONF" >/dev/null 2>&1; then
    local tmp; tmp=$(mktemp)
    if grep -v "^AGENT_MESH_RELAY_TOKEN=" "$CONF" > "$tmp" 2>/dev/null \
       && [ -s "$tmp" ] && cp "$CONF" "$CONF.bak" && cat "$tmp" > "$CONF"; then
      echo "  ✓ AGENT_MESH_RELAY_TOKEN entfernt (Sicherung: $CONF.bak)"
      fixed=$((fixed+1))
    else
      echo "  ❌ Konfiguration konnte nicht bereinigt werden"
    fi
    rm -f "$tmp"
  fi

  [ "$fixed" -eq 0 ] && echo "  nichts zu tun"

  echo ""
  echo "Nicht automatisch behoben (braucht eine Entscheidung oder Rechte):"
  echo "  · abweichende Dateien in einem Installationsverzeichnis → sudo cp aus dem Framework-Klon"
  echo "  · Schlüsselwechsel eines anderen Agents → agent-mesh vault repin <agent>"
  echo "  · Dienste (Relay, Dashboard, watch) → neu starten"
  echo "  Vollständiger Befund: agent-mesh doctor --security"
  return 0
}

# ── agent-mesh fleet ───────────────────────────────────────────────────────
# Was der Hub über alle Agents weiß, ohne einen einzigen zu fragen: jeder legt
# bei `sync` seinen Report als agents/<name>/report.json ab, hier werden sie
# zusammengeführt. Wichtig ist die Spalte "alt" — ein Bericht von vorgestern
# beschreibt nicht den heutigen Zustand, und das muss man SEHEN, statt es zu
# übersehen.
# ── Ein Agent, der absichtlich weg ist ────────────────────────────────────
#
# Die nucbox ist ausgeschaltet, weil eine SSD fehlt. Die Flottenübersicht führt
# sie trotzdem als Störung und empfiehlt, dort einen Dienst einzurichten — auf
# einer Maschine, die niemand einschalten kann. Ein Alarm, der dauerhaft falsch
# steht, entwertet jeden anderen: wer die rote Zeile drei Tage lang ignoriert
# hat, ignoriert auch die vierte, die stimmt.
#
# Die Pause steht im geteilten Repo, nicht lokal — die betroffene Maschine ist
# ja gerade aus. Und sie kann nichts verbergen: meldet sich ein pausierter
# Agent doch, sagt die Übersicht das und verlangt, die Pause aufzuheben. Eine
# vergessene Pause darf keinen echten Ausfall zudecken.
pause_dir() { echo "$MEMORIES_DIR/pauses"; }

cmd_pause() {
  load_conf
  local who="${1:-}"; shift 2>/dev/null || true
  local why="$*"
  [ -n "$who" ] || die "agent-mesh pause <agent> [grund]"
  [ -d "$MEMORIES_DIR/agents/$who" ] || warn "'$who' ist im Verbund nicht bekannt — Pause wird trotzdem vermerkt."
  # Erst holen, dann schreiben, dann mit push_retry veröffentlichen. Die erste
  # Fassung pushte blank — und scheiterte prompt, weil ein anderer Agent main
  # in der Zwischenzeit bewegt hatte. Für genau das gibt es push_retry seit
  # v1.9; es nicht zu benutzen war der Fehler, nicht die Nebenläufigkeit.
  ( cd "$MEMORIES_DIR" && git pull --rebase -q origin main >/dev/null 2>&1 ) || true
  mkdir -p "$(pause_dir)"
  "$PYTHON_BIN" - "$(pause_dir)/$who.json" "$who" "${why:-ohne Angabe}" "$AGENT_NAME" << 'PYPAUSE'
import json, sys, time
path, who, why, by = sys.argv[1:5]
json.dump({"agent": who, "reason": why, "by": by,
           "since": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
          open(path, "w"), indent=2, ensure_ascii=False)
PYPAUSE
  ( cd "$MEMORIES_DIR" \
    && git add -A "pauses" >/dev/null 2>&1 \
    && git commit -q -m "pause: $who — ${why:-ohne Angabe}" >/dev/null 2>&1 \
    && push_retry ) \
    && echo "⏸️  '$who' gilt als absichtlich weg: ${why:-ohne Angabe}" \
    || die "Pause konnte nicht veröffentlicht werden — 'agent-mesh sync' und nochmal."
  echo "   Aufheben: agent-mesh resume $who"
}

cmd_resume() {
  load_conf
  local who="${1:-}"
  [ -n "$who" ] || die "agent-mesh resume <agent>"
  ( cd "$MEMORIES_DIR" && git pull --rebase -q origin main >/dev/null 2>&1 ) || true
  [ -f "$(pause_dir)/$who.json" ] || { info "'$who' ist nicht pausiert."; return 0; }
  rm -f "$(pause_dir)/$who.json"
  ( cd "$MEMORIES_DIR" \
    && git add -A "pauses" >/dev/null 2>&1 \
    && git commit -q -m "resume: $who" >/dev/null 2>&1 \
    && push_retry ) \
    && echo "▶️  '$who' wird wieder als Teil des Verbunds erwartet." \
    || die "Aufhebung konnte nicht veröffentlicht werden — 'agent-mesh sync' und nochmal."
}

# Berichte einsammeln — seit v1.34.0 von je einer eigenen Referenz pro Agent.
#
# Die Referenzen holen ist EIN Rundlauf und rührt main nicht an. Gelesen wird
# ohne Auschecken, direkt aus dem Objekt.
collect_reports() {   # collect_reports <zielverzeichnis>
  local out="$1" ref agent
  (cd "$MEMORIES_DIR" && git fetch --force --quiet origin \
     "refs/heads/reports/*:refs/remotes/origin/reports/*" 2>/dev/null) || true

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    agent="${ref##*/}"
    mkdir -p "$out/$agent"
    (cd "$MEMORIES_DIR" && git show "$ref:report.json" 2>/dev/null) > "$out/$agent/report.json" 2>/dev/null || true
    [ -s "$out/$agent/report.json" ] || rm -rf "$out/$agent"
  done << REFS
$(cd "$MEMORIES_DIR" && git for-each-ref --format='%(refname)' 'refs/remotes/origin/reports/*' 2>/dev/null)
REFS

  # Übergangsweise auch die alten Berichte auf main lesen. Ohne das wäre die
  # Flotte während des Rollouts blind für jeden Agenten, der noch nicht
  # nachgezogen hat — und ausgerechnet die sind die interessanten. Fällt weg,
  # sobald alle auf v1.34.0 stehen.
  local legacy
  for legacy in "$MEMORIES_DIR"/agents/*/report.json; do
    [ -f "$legacy" ] || continue
    agent=$(basename "$(dirname "$legacy")")
    [ -d "$out/$agent" ] && continue     # die eigene Referenz hat Vorrang
    mkdir -p "$out/$agent"
    cp "$legacy" "$out/$agent/report.json"
  done
}

cmd_fleet() {
  load_conf
  local dir; dir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN
  collect_reports "$dir"
  local n=0 f
  for f in "$dir"/*/report.json; do [ -f "$f" ] && n=$((n+1)); done
  if [ "$n" -eq 0 ]; then
    info "Noch keine Berichte. Jeder Agent veröffentlicht einen beim sync."
    return 0
  fi
  "$PYTHON_BIN" - "$dir" "$(git -C "$MEMORIES_DIR" show origin/main:VERSION 2>/dev/null || echo '')" \
    "$(pause_dir)" << 'PYFLEET'
import calendar, json, os, sys, time, glob

base, newest = sys.argv[1], sys.argv[2].strip()

# Wer ist absichtlich weg? Das ist keine Störung und darf keine sein.
paused = {}
for p in glob.glob(os.path.join(sys.argv[3] if len(sys.argv) > 3 else "", "*.json")):
    try:
        d = json.load(open(p, encoding="utf-8"))
        paused[d.get("agent") or os.path.basename(p)[:-5]] = d
    except Exception:
        pass

rows = []
for path in sorted(glob.glob(os.path.join(base, "*", "report.json"))):
    try:
        r = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        # "defekt" allein hilft niemandem weiter — der Anfang der Datei und
        # der Parser-Fehler sagen in einer Zeile, was schiefging.
        try:
            head = open(path, encoding="utf-8", errors="replace").read(70).replace("\n", "\\n")
        except Exception:
            head = "(nicht lesbar)"
        size = os.path.getsize(path) if os.path.exists(path) else 0
        rows.append({"agent": os.path.basename(os.path.dirname(path)),
                     "broken": True, "why": f"{size} B, {type(e).__name__}: {head[:60]}"})
        continue
    rows.append(r)

def age(ts):
    # Der Zeitstempel ist UTC. time.mktime() deutet ihn als Ortszeit, und ein
    # Ausgleich ueber time.timezone geht in der Sommerzeit um eine Stunde
    # daneben — timegm rechnet direkt in UTC.
    try:
        t = calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return None
    return (time.time() - t) / 3600.0

def fmt_age(h):
    if h is None: return "?"
    if h < 1:   return f"{int(h*60)}m"
    if h < 48:  return f"{int(h)}h"
    return f"{int(h/24)}d"

# Die neueste bekannte Version ist der Massstab, wenn origin nichts liefert
if not newest:
    newest = max([r.get("version", "") for r in rows if not r.get("broken")] or [""])

# Ab wann ist Schweigen ein Befund? Jeder Agent erneuert sein Lebenszeichen
# stuendlich (AGENT_MESH_HEARTBEAT). Wer zwei Stunden nichts gesagt hat, hat
# nicht "einen alten Bericht" — bei dem läuft der watch-Dienst nicht mehr,
# und er bekommt weder Update noch Nachricht noch Wartungssignal mit.
STALE_H = 2

print(f"{'AGENT':<24} {'VERSION':<9} {'LETZTES LZ':<11} {'TRUST':<6} {'KEYS':<6} {'RELEASE':<10} {'SEC':<7} PROBLEME")
print("─" * 108)
stale, behind, unhealthy = 0, 0, 0
dead = []
for r in rows:
    if r.get("broken"):
        print(f"{r['agent']:<24} {'?':<9} {'defekt':<8} — {r.get('why', 'nicht lesbar')}")
        unhealthy += 1
        continue
    a = (r.get("agent") or "?")[:23]
    v = r.get("version") or "?"
    h = age(r.get("ts", ""))
    pz = paused.get(r.get("agent") or a)
    old = h is not None and h > STALE_H
    if old and not pz:
        stale += 1
        dead.append(a)
    vmark = "" if v == newest else "!"
    # Eine ausgeschaltete Maschine kann nicht aktualisieren. Sie deshalb als
    # rückständig zu zählen, macht aus einer Entscheidung einen Mangel.
    if vmark and not pz: behind += 1
    trust = "ja" if r.get("trust") else "NEIN"
    keys = "ok" if "sign-publiziert" in (r.get("keys") or "") else "FEHLT"
    rel = (r.get("release") or "?")[:10]
    bad = r.get("bad", 0)
    sec = "ok" if bad == 0 else f"{bad} offen"
    if (bad or trust == "NEIN" or keys == "FEHLT" or vmark) and not pz: unhealthy += 1
    # Ein bekannter Fehlergrund ist wichtiger als der erste Sicherheitsbefund:
    # er erklärt, warum dieser Agent hinterherhinkt.
    first = (r.get("last_error") or "") or (r.get("issues") or [""])[0]
    if pz:
        # Eine vergessene Pause darf keinen echten Ausfall zudecken: meldet
        # sich ein pausierter Agent doch, wird genau das gesagt.
        if not old:
            first = f"pausiert, meldet sich aber — agent-mesh resume {a}"
            unhealthy += 1
        else:
            first = f"pausiert: {pz.get('reason') or 'ohne Angabe'}"
    first = first[:44]
    mark = " PAUSE" if pz else (" STILL" if old else "")
    print(f"{a:<24} {v+vmark:<9} {fmt_age(h)+mark:<11} "
          f"{trust:<6} {keys:<6} {rel:<10} {sec:<7} {first}")

print("─" * 108)
pz_n = sum(1 for r in rows if not r.get("broken") and paused.get(r.get("agent")))
print(f"{len(rows)} Agent(en) · {behind} nicht auf v{newest} · {stale} ohne Lebenszeichen "
      f"· {unhealthy} mit offenen Punkten" + (f" · {pz_n} pausiert" if pz_n else ""))
# Welche Komponenten laufen im Verbund wirklich — und welche nirgends?
# Ohne diese Zeile ist jede Aufräum-Entscheidung geraten: relay, webhook und
# dashboard werden auf jede Maschine installiert, von der CLI aber nie
# aufgerufen. Was nirgends läuft, kann weg; was irgendwo läuft, nicht.
KNOWN = ["relay", "webhook", "dashboard", "converge-timer", "watch-alt"]
where = {c: [] for c in KNOWN}
unknown = {}
for r in rows:
    if r.get("broken"):
        continue
    for c in (r.get("components") or []):
        (where[c] if c in where else unknown.setdefault(c, [])).append(r.get("agent", "?"))
live = [r for r in rows if not r.get("broken")]
reporting = [r for r in live if r.get("components") is not None]
if reporting:
    print("")
    # "nirgends" darf NICHT heissen "in keinem Bericht, der es sagen kann".
    # Ein Agent auf einer alten Fassung kennt das Feld nicht — seine Dienste
    # wären unsichtbar, und eine Aufräum-Entscheidung auf dieser Grundlage
    # würde löschen, was anderswo läuft.
    complete = len(reporting) == len(live)
    scope = "alle" if complete else f"{len(reporting)} von {len(live)}"
    print(f"Laufende Komponenten ({scope} Agent(en) berichten das):")
    for c in KNOWN + sorted(unknown):
        hosts = where.get(c, unknown.get(c, []))
        print(f"  {c:<16} {', '.join(hosts) if hosts else '—'}")
    silent = [c for c in KNOWN if not where[c]]
    if silent and complete:
        print(f"  → läuft nirgends im Verbund: {', '.join(silent)}")
    elif silent:
        missing = [r.get("agent", "?") for r in live if r.get("components") is None]
        print(f"  → ohne Angabe: {', '.join(missing)} — solange die schweigen, heisst")
        print("    ein leerer Eintrag NICHT, dass die Komponente nirgends läuft.")

if dead:
    print("")
    print(f"❌ Kein Lebenszeichen seit über {STALE_H}h: {', '.join(dead)}")
    print("   Dort läuft der watch-Dienst nicht. Ein stiller Agent bekommt weder")
    print("   Update noch Nachricht noch Wartungssignal mit — er fällt lautlos aus")
    print("   dem Verbund, und die Flotte sieht trotzdem grün aus.")
    print("   Auf der Maschine:  agent-mesh service status && agent-mesh service install")
PYFLEET
}

# ── agent-mesh report [--json] ─────────────────────────────────────────────
# Kompakter, kopierbarer Zustandsbericht aus nachprüfbaren Beobachtungen.
# Entstanden, weil beim ersten Flotten-Rollout vier Prosa-Berichte Zustände
# beschrieben, die es nicht gab — nicht aus Nachlässigkeit, sondern weil die
# Werkzeuge meldeten, was sie TATEN, nicht was dabei herauskam.
cmd_report() {
  # --publish: nur das Lebenszeichen auf die eigene Referenz schieben. Der
  # billigste Weg, im Verbund sichtbar zu bleiben — ein Push, kein Abgleich.
  if [ "${1:-}" = "--publish" ]; then
    load_conf
    publish_report --force
    return $?
  fi
  report_facts
  if [ "${1:-}" = "--json" ]; then
    "$PYTHON_BIN" - "$R_TS" "$R_HOST" "$R_OS" "$R_AGENT" "$R_VERSION" "$R_COMMIT" \
      "$R_REMOTE" "$R_INSTALLS" "$R_ONPATH" "$R_TRUST" "$R_RELEASE" "$R_KEYS" \
      "$R_TOKEN" "$R_WATCHER" "$R_OK" "$R_BAD" "$R_ISSUES" "$R_COMPONENTS" \
      "$R_LASTERR" << 'PYJSON'
import json, sys
k = ["ts","host","os","agent","version","commit","remote","installs","onpath",
     "trust","release","keys","relay_token","watcher","ok","bad","issues","components",
     "last_error"]
v = sys.argv[1:20]
# Argumente kommen als str mit surrogateescape herein — ein kaputtes Byte
# überlebt bis in die Datei und macht sie unlesbar. Einmal sauber durch UTF-8
# schicken, dann kann kein Aufrufer diesen Bericht mehr vergiften.
def clean(x):
    return x.encode("utf-8", "replace").decode("utf-8", "replace")

d = dict(zip(k, [clean(x) for x in v]))
# Hier kürzen, nicht in der Shell: an dieser Stelle sind es nachweislich
# Zeichen und keine Bytes.
d["commit"] = d["commit"][:58]
d["ok"] = int(d["ok"] or 0); d["bad"] = int(d["bad"] or 0)
d["installs"] = [x for x in d["installs"].split() if x]
d["issues"] = [x for x in d["issues"].split("\n") if x.strip()]
d["components"] = [x for x in d.get("components", "").split() if x]
print(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=True))
PYJSON
    return 0
  fi

  echo "═══ agent-mesh report ═══"
  printf '%-14s %s\n' "zeit" "$R_TS"
  printf '%-14s %s (%s, bash %s)\n' "host" "$R_HOST" "$R_OS" "${BASH_VERSION%%(*}"
  printf '%-14s %s\n' "agent" "${R_AGENT:-NICHT INITIALISIERT}"
  if [ -n "$R_VERSION" ]; then
    printf '%-14s v%s  (%.58s)\n' "framework" "$R_VERSION" "$R_COMMIT"
    if [ "$R_VERSION" = "$R_REMOTE" ]; then printf '%-14s v%s — aktuell\n' "remote" "$R_REMOTE"
    else printf '%-14s v%s  ⚠️  UPDATE NÖTIG\n' "remote" "$R_REMOTE"; fi
  else
    printf '%-14s %s\n' "framework" "KEIN KLON"
  fi
  local i
  for i in $R_INSTALLS; do
    case "${i##*:}" in
      0/0) printf '%-14s %s — nicht vergleichbar (kein Klon)\n' "install" "${i%%:*}" ;;
      0/*) printf '%-14s %s — %s Dateien, deckungsgleich\n' "install" "${i%%:*}" "${i##*/}" ;;
      *)   printf '%-14s %s — %s ABWEICHEND  ⚠️\n' "install" "${i%%:*}" "${i##*:}" ;;
    esac
  done
  printf '%-14s %s\n' "auf PATH" "${R_ONPATH:-NICHT GEFUNDEN}"
  printf '%-14s %s\n' "trust" "${R_TRUST:-FEHLT — agent-mesh trust}"
  printf '%-14s %s\n' "release" "$R_RELEASE"
  printf '%-14s %s\n' "läuft hier" "${R_COMPONENTS:-nur die Konvergenz}"
  [ -n "$R_LASTERR" ] && printf '%-14s %s  ⚠️\n' "letzter Fehler" "$R_LASTERR"
  [ -n "$R_KEYS" ] && printf '%-14s %s\n' "keys" "$R_KEYS"
  [ "$R_TOKEN" = "ja" ] && printf '%-14s %s\n' "relay-token" "NOCH IN DER CONF  ⚠️"
  printf '%-14s %s\n' "watcher" "$R_WATCHER"
  echo "───"
  printf '%-14s %s bestanden, %s offen\n' "security" "$R_OK" "$R_BAD"
  [ -n "$R_ISSUES" ] && printf '%s\n' "$R_ISSUES" | sed 's/^/  /'
  echo "═══ ende ═══"
  return 0
}


cmd_doctor() {
  local mode="all"
  [ "${1:-}" = "--vault" ] && mode="vault"
  [ "${1:-}" = "--net" ] && mode="net"
  [ "${1:-}" = "--security" ] && mode="security"
  [ "${1:-}" = "--fix" ] && mode="fix"

  load_conf
  if [ "$mode" = "security" ]; then
    security_checks
    return 0
  fi
  if [ "$mode" = "fix" ]; then
    doctor_fix
    return 0
  fi

  local ok=0 fail=0

  pass() { ok=$((ok+1)); echo "  ✅ $*"; }
  bad()  { fail=$((fail+1)); echo "  ❌ $*"; }

  echo "🔍 Agent-Mesh Doctor (Agent: $AGENT_NAME)"
  echo ""

  # ── Vault/Encryption-Checks ──
  if [ "$mode" != "net" ]; then
    echo "── Vault & Verschlüsselung ──"

    # sops
    if command -v sops >/dev/null 2>&1; then
      pass "sops: $(sops --version 2>/dev/null | head -1 | awk '{print $NF}')"
    elif command -v sops.exe >/dev/null 2>&1; then
      pass "sops (Windows): $(sops.exe --version 2>/dev/null | head -1 | awk '{print $NF}')"
    else
      bad "sops fehlt — verschlüsselte Nachrichten/Vault NICHT verfügbar!"
      echo "     Installieren: macOS 'brew install sops' · Windows 'scoop install sops' · Linux 'apt install sops'"
      echo "     oder: https://github.com/getsops/sops/releases"
    fi

    # age/age-keygen
    if command -v "$AGE_BIN" >/dev/null 2>&1 || command -v age.exe >/dev/null 2>&1; then
      pass "age: vorhanden"
    else
      bad "age fehlt — Key-Verschlüsselung nicht verfügbar!"
      echo "     Installieren: macOS 'brew install age' · Windows 'scoop install age' · Linux 'apt install age'"
    fi
    if command -v "$AGE_KEYGEN_BIN" >/dev/null 2>&1; then
      pass "age-keygen: vorhanden"
    else
      bad "age-keygen fehlt — Key-Erzeugung nicht verfügbar!"
    fi

    # Lokaler Key lesbar?
    if [ -f "$AGE_KEY_FILE" ] && [ -r "$AGE_KEY_FILE" ]; then
      pass "Lokaler Key lesbar: $AGE_KEY_FILE"
    else
      bad "Lokaler Key fehlt/nicht lesbar: $AGE_KEY_FILE"
      echo "     → agent-mesh init <name> neu ausführen"
    fi

    # Empfänger-Key-Registry
    local nkeys
    nkeys=$(ls "$MEMORIES_DIR"/vault/keys/*.pub 2>/dev/null | wc -l | tr -d ' ')
    if [ "${nkeys:-0}" -gt 0 ]; then
      pass "Empfänger-Registry: $nkeys Public-Key(s)"
    else
      bad "Keine Empfänger-Keys in vault/keys/ — Nachrichten können nicht verschlüsselt werden"
    fi

    # Selbsttest: verschlüsseln + entschlüsseln (nur wenn sops+age da)
    if command -v sops >/dev/null 2>&1 && [ -f "$AGE_KEY_FILE" ] && command -v "$AGE_BIN" >/dev/null 2>&1; then
      local tmp self_test
      tmp=$(mktemp)
      echo '{"doctor":"ok"}' > "$tmp"
      if SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops --encrypt \
           --age "$AGE_PUB" --input-type json --output-type yaml "$tmp" 2>/dev/null \
         | SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops -d --input-type yaml --output-type json /dev/stdin 2>/dev/null \
         | grep '"doctor": "ok"' >/dev/null; then
        pass "Verschlüsselungs-Selbsttest: Encrypt+Decrypt ok"
      else
        bad "Selbsttest fehlgeschlagen — sops/age-Konfiguration prüfen"
      fi
      rm -f "$tmp"
    fi
    echo ""
  fi

  # ── Netz/GitHub-Checks ──
  if [ "$mode" != "vault" ]; then
    echo "── GitHub & Repos ──"

    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      local who
      who=$(gh api user --jq .login 2>/dev/null || echo "?")
      pass "gh eingeloggt als: $who"
    else
      bad "gh nicht eingeloggt — 'agent-mesh connect' ausführen (Browser-Auth)"
    fi

    if [ -d "$MEMORIES_DIR/.git" ]; then
      pass "Privates Repo geklont: $MEMORIES_DIR"
    else
      bad "Privates Repo fehlt — 'agent-mesh init <name>' ausführen"
    fi
    if [ -d "$FRAMEWORK_DIR/.git" ]; then
      pass "Framework-Repo geklont: $FRAMEWORK_DIR"
    else
      warn "Framework-Repo fehlt (optional — Self-Update funktioniert dann nicht)"
    fi

    # Push-Rechte prüfen
    if [ -d "$MEMORIES_DIR/.git" ]; then
      if (cd "$MEMORIES_DIR" && git ls-remote origin HEAD >/dev/null 2>&1); then
        pass "Repo erreichbar + lesbar (git ls-remote ok)"
      else
        bad "Repo nicht erreichbar — Auth/Zugriff prüfen (gh auth status)"
      fi
    fi
    echo ""
  fi

  echo "──────────────────────────────"
  if [ "$fail" -eq 0 ]; then
    echo "✅ Alle $ok Checks bestanden — Agent ist voll einsatzfähig."
  else
    echo "⚠️  $fail von $((ok+fail)) Checks fehlgeschlagen — siehe oben für Fixes."
    [ "$mode" = "all" ] && echo "    Tipp: 'agent-mesh doctor --vault' für nur Vault-Checks"
  fi
}
