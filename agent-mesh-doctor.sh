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
      bad "Kein Tag '$tag' im Framework-Klon — Releases werden nicht signiert?"
      note "Maintainer: siehe docs/RELEASING.md"
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
    local diffs=0 f base
    for f in "$fw"/agent-mesh "$fw"/agent-mesh-*.sh "$fw"/agent-mesh-*.py "$fw"/agent-mesh-*.js; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      [ -f "$d/$base" ] || continue
      cmp -s "$f" "$d/$base" || diffs=$((diffs+1))
    done
    if [ "$diffs" -eq 0 ]; then
      pass "$d — aktuell"
    else
      bad "$d — $diffs Datei(en) weichen vom Framework-Klon ab (veralteter Stand)"
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
  if [ "$fail" -eq 0 ]; then
    echo "✅ $ok Prüfungen bestanden — Sicherheitsstand v1.13.0 erreicht."
  else
    echo "⚠️  $ok bestanden, $fail offen — siehe die Hinweise oben."
    echo "   Vollständige Anleitung: $FRAMEWORK_DIR/MIGRATIONS.md"
  fi
  return 0
}

cmd_doctor() {
  local mode="all"
  [ "${1:-}" = "--vault" ] && mode="vault"
  [ "${1:-}" = "--net" ] && mode="net"
  [ "${1:-}" = "--security" ] && mode="security"

  load_conf
  if [ "$mode" = "security" ]; then
    security_checks
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
         | grep -q '"doctor": "ok"'; then
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
