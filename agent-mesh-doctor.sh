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

set -euo pipefail

cmd_doctor() {
  local mode="all"
  [ "${1:-}" = "--vault" ] && mode="vault"
  [ "${1:-}" = "--net" ] && mode="net"

  load_conf
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
