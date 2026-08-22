#!/usr/bin/env bash
# agent-mesh-a2a — Agent-to-Agent-Kommunikation + Rollen für das Agent-Mesh.
#
# Konzept:
#   Nachrichten laufen als JSON-Dateien über das PRIVATE Repo (Git-Queue).
#   Jeder Agent hat eine Mailbox unter messages/<empfaenger>/. Der Sender
#   committet+pusht, der Empfänger pullt und verarbeitet bei mesh sync.
#   Zusätzlich gibt es Agent Cards (Rollen + Fähigkeiten) für Discovery.
#
# Rollen:
#   hub       — zentraler Ansprechpartner, routet Nachrichten weiter
#   worker    — führt Aufgaben aus (Default)
#   specialist — Spezialist für ein Gebiet (z.B. media, db, web)
#
# Usage (in mesh integriert):
#   mesh send <empfaenger> <text>        Nachricht senden
#   mesh inbox                            Eigene Mailbox lesen
#   mesh reply <msg-id> <text>            Auf Nachricht antworten
#   mesh route <empfaenger> <text>        Über den Hub senden (Rolle hub)
#   mesh role <rolle> [beschreibung]      Eigene Rolle setzen
#   mesh agents                           Agent Cards aller Agents zeigen

MESSAGES_DIR="$MEMORIES_DIR/messages"
CARDS_FILE="$MEMORIES_DIR/agents/_cards.json"

# ─────────────────────────── Agent Card ───────────────────────────
card_path() { echo "$MEMORIES_DIR/agents/$AGENT_NAME/card.json"; }

get_card() {
  local f; f=$(card_path)
  if [ -f "$f" ]; then
    cat "$f"
  else
    echo "{\"agent\":\"$AGENT_NAME\",\"role\":\"worker\",\"capabilities\":[],\"endpoint\":null}"
  fi
}

update_card() {
  # $1 = JSON-Snippet zum Mergen (z.B. {"role":"hub"})
  local f; f=$(card_path)
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    "$PYTHON_BIN" - "$f" "$1" << 'PYEOF'
import json, sys
path, merge = sys.argv[1], json.loads(sys.argv[2])
with open(path) as fh: card = json.load(fh)
card.update(merge)
with open(path, "w") as fh: json.dump(card, fh, indent=2, ensure_ascii=False)
PYEOF
  else
    "$PYTHON_BIN" - "$f" "$1" << 'PYEOF'
import json, sys
path, merge = sys.argv[1], json.loads(sys.argv[2])
card = {"agent": "", "role": "worker", "capabilities": [], "endpoint": None}
card.update(merge)
with open(path, "w") as fh: json.dump(card, fh, indent=2, ensure_ascii=False)
PYEOF
  fi
}

# ─────────────────────────── Mailbox (Git-Queue, VERSCHLÜSSELT) ───────────────────────────
# Security v1.1: Jede Nachricht wird mit dem Public-Key des EMPFÄNGERS
# verschlüsselt (sops). Nur Sender + Empfänger können sie lesen.
#   messages/<empfaenger>/<id>.json   ← Klartext-Header (Metadaten: from/to/ts)
#   messages/<empfaenger>/<id>.json.enc  ← sops-verschlüsselter Text (nur Empfänger lesbar)

next_msg_id() {
  # Monotone ID: timestamp + kurzer Zufall (Kollisionen unwahrscheinlich)
  echo "$(date -u +%Y%m%d%H%M%S)-$RANDOM"
}

msg_file() { echo "$MESSAGES_DIR/$1/$2.json"; }
msg_enc() { echo "${1}.enc"; }

# Verschlüsselten Text erzeugen (JSON-Objekt mit "text" — sops-verschlüsselt)
encrypt_text() {
  # $1 = Empfänger-Key (bech32), $2 = Klartext
  local recipient="$1" text="$2" tmp
  tmp=$(mktemp)
  "$PYTHON_BIN" - "$tmp" "$text" << 'EOF'
import json, sys
with open(sys.argv[1], "w") as f: json.dump({"text": sys.argv[2]}, f)
EOF
  if ! SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops --encrypt \
    --age "$recipient" --input-type json --output-type yaml "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    # Issue #2: klare, plattformspezifische Diagnose statt kryptischem Fehler!
    die "Verschlüsselung fehlgeschlagen. sops nicht gefunden oder Age-Key nicht nutzbar.
  → Diagnose: 'agent-mesh doctor --vault'
  → sops installieren: macOS 'brew install sops' · Windows 'scoop install sops' · Linux 'apt install sops'
  → Sicherheit: KEIN Fallback auf Klartext — Nachricht wird nicht gesendet."
  fi
  rm -f "$tmp"
}

cmd_send() {
  load_conf
  [ $# -ge 2 ] || die "Usage: agent-mesh send <empfaenger> <text>"
  local to="$1"; shift
  local text="$*"
  local id; id=$(next_msg_id)
  mkdir -p "$MESSAGES_DIR/$to"

  # Empfänger-Key laden (muss registriert sein!)
  local to_pub; to_pub=$(agent_pub "$to")

  # Verschlüsselten Text erzeugen (nur Empfänger kann lesen)
  local enc; enc=$(encrypt_text "$to_pub" "$text")
  local f; f=$(msg_file "$to" "$id")
  cat > "$f" << EOF
{
  "id": "$id",
  "from": "$AGENT_NAME",
  "to": "$to",
  "type": "message",
  "encrypted": true,
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "reply_to": null
}
EOF
  # Verschlüsselten Text als separate Datei ablegen
  echo "$enc" > "$(msg_enc "$f")"

  cd "$MEMORIES_DIR" && git add "messages/$to/$id.json" "messages/$to/$id.json.enc" >/dev/null 2>&1
  git commit -m "msg: $AGENT_NAME → $to (verschlüsselt)" >/dev/null 2>&1
  git push origin HEAD >/dev/null 2>&1 || info "Push fehlgeschlagen (Remote prüfen)"
  info "✅ Verschlüsselte Nachricht an '$to' gesendet (ID: $id)"
}

cmd_reply() {
  load_conf
  [ $# -ge 2 ] || die "Usage: agent-mesh reply <msg-id> <text>"
  local reply_to="$1"; shift
  local text="$*"
  # Original finden (in welcher Mailbox liegt die msg-id?)
  local orig=""
  orig=$(find "$MESSAGES_DIR" -name "$reply_to.json" 2>/dev/null | head -1)
  [ -n "$orig" ] || die "Original-Nachricht $reply_to nicht gefunden"
  local from
  from=$("$PYTHON_BIN" -c "import json; print(json.load(open('$orig'))['from'])")
  local id; id=$(next_msg_id)
  mkdir -p "$MESSAGES_DIR/$from"

  # Empfänger-Key laden + verschlüsseln
  local to_pub; to_pub=$(agent_pub "$from")
  local enc; enc=$(encrypt_text "$to_pub" "$text")
  local f; f=$(msg_file "$from" "$id")
  cat > "$f" << EOF
{
  "id": "$id",
  "from": "$AGENT_NAME",
  "to": "$from",
  "type": "message",
  "encrypted": true,
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "reply_to": "$reply_to"
}
EOF
  echo "$enc" > "$(msg_enc "$f")"

  cd "$MEMORIES_DIR" && git add "messages/$from/$id.json" "messages/$from/$id.json.enc" >/dev/null 2>&1
  git commit -m "reply: $AGENT_NAME → $from ($reply_to, verschlüsselt)" >/dev/null 2>&1
  git push origin HEAD >/dev/null 2>&1 || info "Push fehlgeschlagen"
  info "✅ Verschlüsselte Antwort an '$from' gesendet (ID: $id)"
}

cmd_inbox() {
  load_conf
  local dir="$MESSAGES_DIR/$AGENT_NAME"
  [ -d "$dir" ] || { info "Keine Nachrichten."; return; }
  local any=0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "*.enc" ] && continue
    # Nur .json (nicht .enc) verarbeiten
    case "$f" in *.enc) continue;; esac
    any=1
    "$PYTHON_BIN" - "$f" "$f.enc" "$AGE_KEY_FILE" << 'PYEOF'
import json, os, subprocess, sys
meta_path, enc_path, keyfile = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    m = json.load(open(meta_path))
except Exception:
    sys.exit(0)
print(f"── {m['id']} ──")
print(f"  von: {m['from']}  ·  {m['ts']}")
print(f"  an:  {m['to']}")
if m.get("reply_to"): print(f"  antwort auf: {m['reply_to']}")
# Verschlüsselten Text entschlüsseln (eigener Key)
if m.get("encrypted") and os.path.exists(enc_path):
    env = dict(os.environ, SOPS_AGE_KEY_FILE=keyfile)
    try:
        out = subprocess.run(
            ["sops", "-d", "--input-type", "yaml", "--output-type", "json", enc_path],
            capture_output=True, text=True, env=env, timeout=15,
        )
        if out.returncode == 0:
            text = json.loads(out.stdout).get("text", "")
            print(f"  text: {text}")
        else:
            print(f"  text: 🔒 verschlüsselt (dein Key ist kein Empfänger)")
    except Exception:
        print(f"  text: 🔒 verschlüsselt (Entschlüsselung fehlgeschlagen)")
else:
    print(f"  text: {m.get('text', '(kein Text)')}")
print(f"  (Antwort: agent-mesh reply {m['id']} <text>)")
PYEOF
  done
  [ "$any" = "0" ] && info "Keine Nachrichten."
}

# ─────────────────────────── Rollen ───────────────────────────
cmd_role() {
  load_conf
  [ $# -ge 1 ] || die "Usage: agent-mesh role <hub|worker|specialist> [beschreibung]"
  local role="$1"
  case "$role" in
    hub|worker|specialist) ;;
    *) die "Rolle muss sein: hub | worker | specialist" ;;
  esac
  update_card "{\"role\":\"$role\",\"agent\":\"$AGENT_NAME\"}"
  cd "$MEMORIES_DIR" && git add "agents/$AGENT_NAME/card.json" >/dev/null 2>&1
  git commit -m "role: $AGENT_NAME ist jetzt $role" >/dev/null 2>&1
  git push origin HEAD >/dev/null 2>&1 || true
  info "✅ Rolle '$role' gesetzt — Agent Card aktualisiert."
}

# ─────────────────────────── Hub-Routing ───────────────────────────
cmd_route() {
  load_conf
  [ $# -ge 2 ] || die "Usage: agent-mesh route <empfaenger> <text>  (nur als Rolle hub)"
  local card; card=$(get_card)
  local myrole
  myrole=$(echo "$card" | "$PYTHON_BIN" -c "import json,sys; print(json.load(sys.stdin).get('role','worker'))")
  [ "$myrole" = "hub" ] || die "Nur der Hub kann routen (deine Rolle: $myrole)."
  cmd_send "$@"
}

cmd_agents() {
  load_conf
  info "Agenten im Mesh (aus dem privaten Repo):"
  for card in "$MEMORIES_DIR"/agents/*/card.json; do
    [ -f "$card" ] || continue
    "$PYTHON_BIN" - "$card" << 'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
caps = ", ".join(c.get("capabilities", []) or []) or "—"
print(f"  • {c.get('agent','?')}  [Rolle: {c.get('role','worker')}]")
if caps: print(f"      Fähigkeiten: {caps}")
PYEOF
  done
}

# ─────────────────────────── Inbox-Verarbeitung (für Cron) ───────────────────────────
cmd_inbox_process() {
  # Verarbeitet eingehende Nachrichten: markiert sie als gelesen (.processed).
  # Wird vom Cron aufgerufen; die eigentliche Reaktion macht der Agent.
  load_conf
  local dir="$MESSAGES_DIR/$AGENT_NAME"
  [ -d "$dir" ] || { info "Keine Nachrichten."; return 0; }
  local n=0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    [ -f "$f.processed" ] && continue
    n=$((n+1))
    touch "$f.processed"
  done
  if [ "$n" -gt 0 ]; then
    info "📬 $n neue Nachricht(en) für $AGENT_NAME — siehe: mesh inbox"
    cd "$MEMORIES_DIR" && git add "messages/$AGENT_NAME/" >/dev/null 2>&1
    git commit -m "inbox: $n Nachricht(en) verarbeitet ($AGENT_NAME)" >/dev/null 2>&1
    git push origin HEAD >/dev/null 2>&1 || true
  else
    info "Keine neuen Nachrichten."
  fi
}
