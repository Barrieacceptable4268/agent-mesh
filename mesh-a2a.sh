#!/usr/bin/env bash
# mesh-a2a — Agent-to-Agent-Kommunikation + Rollen für das Agent-Mesh.
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
    python3 - "$f" "$1" << 'PYEOF'
import json, sys
path, merge = sys.argv[1], json.loads(sys.argv[2])
with open(path) as fh: card = json.load(fh)
card.update(merge)
with open(path, "w") as fh: json.dump(card, fh, indent=2, ensure_ascii=False)
PYEOF
  else
    python3 - "$f" "$1" << 'PYEOF'
import json, sys
path, merge = sys.argv[1], json.loads(sys.argv[2])
card = {"agent": "", "role": "worker", "capabilities": [], "endpoint": None}
card.update(merge)
with open(path, "w") as fh: json.dump(card, fh, indent=2, ensure_ascii=False)
PYEOF
  fi
}

# ─────────────────────────── Mailbox (Git-Queue) ───────────────────────────
next_msg_id() {
  # Monotone ID: timestamp + kurzer Zufall (Kollisionen unwahrscheinlich)
  echo "$(date -u +%Y%m%d%H%M%S)-$RANDOM"
}

msg_file() { echo "$MESSAGES_DIR/$1/$2.json"; }

cmd_send() {
  load_conf
  [ $# -ge 2 ] || die "Usage: mesh send <empfaenger> <text>"
  local to="$1"; shift
  local text="$*"
  local id; id=$(next_msg_id)
  mkdir -p "$MESSAGES_DIR/$to"
  local f; f=$(msg_file "$to" "$id")
  cat > "$f" << EOF
{
  "id": "$id",
  "from": "$AGENT_NAME",
  "to": "$to",
  "type": "message",
  "text": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text"),
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "reply_to": null
}
EOF
  cd "$MEMORIES_DIR" && git add "messages/$to/$id.json" >/dev/null 2>&1
  git commit -m "msg: $AGENT_NAME → $to" >/dev/null 2>&1
  git push origin HEAD >/dev/null 2>&1 || info "Push fehlgeschlagen (Remote prüfen)"
  info "✅ Nachricht an '$to' gesendet (ID: $id)"
}

cmd_reply() {
  load_conf
  [ $# -ge 2 ] || die "Usage: mesh reply <msg-id> <text>"
  local reply_to="$1"; shift
  local text="$*"
  # Original finden (in welcher Mailbox liegt die msg-id?)
  local orig=""
  orig=$(find "$MESSAGES_DIR" -name "$reply_to.json" 2>/dev/null | head -1)
  [ -n "$orig" ] || die "Original-Nachricht $reply_to nicht gefunden"
  local from
  from=$(python3 -c "import json; print(json.load(open('$orig'))['from'])")
  local id; id=$(next_msg_id)
  mkdir -p "$MESSAGES_DIR/$from"
  local f; f=$(msg_file "$from" "$id")
  cat > "$f" << EOF
{
  "id": "$id",
  "from": "$AGENT_NAME",
  "to": "$from",
  "type": "message",
  "text": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text"),
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "reply_to": "$reply_to"
}
EOF
  cd "$MEMORIES_DIR" && git add "messages/$from/$id.json" >/dev/null 2>&1
  git commit -m "reply: $AGENT_NAME → $from ($reply_to)" >/dev/null 2>&1
  git push origin HEAD >/dev/null 2>&1 || info "Push fehlgeschlagen"
  info "✅ Antwort an '$from' gesendet (ID: $id)"
}

cmd_inbox() {
  load_conf
  local dir="$MESSAGES_DIR/$AGENT_NAME"
  [ -d "$dir" ] || { info "Keine Nachrichten."; return; }
  local any=0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    any=1
    python3 - "$f" << 'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
print(f"── {m['id']} ──")
print(f"  von: {m['from']}  ·  {m['ts']}")
print(f"  an:  {m['to']}")
if m.get("reply_to"): print(f"  antwort auf: {m['reply_to']}")
print(f"  text: {m['text']}")
print(f"  (Antwort: mesh reply {m['id']} <text>)")
PYEOF
  done
  [ "$any" = "0" ] && info "Keine Nachrichten."
}

# ─────────────────────────── Rollen ───────────────────────────
cmd_role() {
  load_conf
  [ $# -ge 1 ] || die "Usage: mesh role <hub|worker|specialist> [beschreibung]"
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
  [ $# -ge 2 ] || die "Usage: mesh route <empfaenger> <text>  (nur als Rolle hub)"
  local card; card=$(get_card)
  local myrole
  myrole=$(echo "$card" | python3 -c "import json,sys; print(json.load(sys.stdin).get('role','worker'))")
  [ "$myrole" = "hub" ] || die "Nur der Hub kann routen (deine Rolle: $myrole)."
  cmd_send "$@"
}

cmd_agents() {
  load_conf
  info "Agenten im Mesh (aus dem privaten Repo):"
  for card in "$MEMORIES_DIR"/agents/*/card.json; do
    [ -f "$card" ] || continue
    python3 - "$card" << 'PYEOF'
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
