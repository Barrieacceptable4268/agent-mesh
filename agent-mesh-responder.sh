#!/usr/bin/env bash
# agent-mesh-responder — Auto-Responder: beantwortet eingehende Nachrichten.
#
# Der watch-Daemon ruft `agent-mesh respond` auf, wenn neue Nachrichten in der
# Mailbox sind. Der Responder generiert eine Antwort (LLM wenn Key vorhanden,
# sonst Default-Template) und sendet sie per `agent-mesh reply` zurück.
#
# Sicherheit:
#   - Antwortet NUR auf neue Nachrichten (reply_to: null = Gesprächsstarter)
#     → kein Ping-Pong zwischen Agents (Antworten auf Antworten werden ignoriert)
#   - Keine Secrets im Antwort-Kontext (nur Text der Original-Nachricht)
#   - Kein Loop: .responded-Marker pro Nachricht
#   - Konfigurierbar: AGENT_MESH_AUTO_RESPOND=0 deaktiviert (in agent-mesh.conf)

set -euo pipefail

cmd_respond() {
  load_conf

  # Auto-Respond aus? (Default: an)
  local enabled
  enabled=$(grep "^AGENT_MESH_AUTO_RESPOND=" "$CONF" | cut -d= -f2- || true)
  if [ "${enabled:-1}" = "0" ]; then
    [ "${1:-}" = "--force" ] || { info "Auto-Respond deaktiviert (AGENT_MESH_AUTO_RESPOND=0 in $CONF)"; return 0; }
  fi

  local dir="$MESSAGES_DIR/$AGENT_NAME"
  [ -d "$dir" ] || { info "Keine Mailbox."; return 0; }

  local answered=0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    case "$f" in *.enc) continue;; esac

    # Nur neue, noch nicht beantwortete Nachrichten
    [ -f "$f.responded" ] && continue

    # Metadaten lesen
    local from="" reply_to="" id="" text=""
    id=$(basename "$f" .json)
    from=$("$PYTHON_BIN" -c "import json;print(json.load(open('$f')).get('from',''))" 2>/dev/null || true)
    reply_to=$("$PYTHON_BIN" -c "import json;print(json.load(open('$f')).get('reply_to') or '')" 2>/dev/null || true)

    # Nur Gesprächsstarter beantworten (kein Ping-Pong!)
    [ -n "$reply_to" ] && { touch "$f.responded"; continue; }
    # Nicht an uns selbst antworten
    [ "$from" = "$AGENT_NAME" ] && { touch "$f.responded"; continue; }
    [ -z "$from" ] && { touch "$f.responded"; continue; }

    # Nachricht entschlüsseln UND Absender prüfen (Befund 10).
    # Ein Auto-Responder, der auf unbelegte Absender antwortet, ist ein
    # Werkzeug für jeden, der eine Nachricht fälschen kann — deshalb wird
    # hier ausschliesslich auf "ok" reagiert.
    local res status
    res=$(read_message "$f" "$from")
    status="${res%%|*}"; text="${res#*|}"
    if [ "$status" != "ok" ]; then
      case "$status" in
        forged) warn "🚨 $id von '$from': Signatur ungültig — keine Antwort, nicht gelöscht." ;;
        unsigned) warn "⚠️  $id von '$from': unsigniert — keine automatische Antwort." ;;
      esac
      touch "$f.responded"
      continue
    fi

    # Nur auf FRAGEN/Aufträge antworten — nicht auf Bestätigungen (UPDATE-OK, READY…)
    # und nicht auf Nachrichten ohne Fragezeichen/Handlungsaufforderung
    local lower
    lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    local is_question=0
    echo "$text" | grep -q "?" && is_question=1
    echo "$lower" | grep -qE "bitte|update|mach|schick|antworte|wünsche|verbesserung|wie geht" && is_question=1
    # Reine Bestätigungen (kurz, ohne Frage/Auftrag) ignorieren
    echo "$lower" | grep -qE "^(update-ok|ok|done|ready|erledigt|verstanden|✅|🙏)" && is_question=0
    if [ "$is_question" = "0" ]; then
      touch "$f.responded"
      continue
    fi

    # Antwort generieren
    local answer
    answer=$(generate_reply "$from" "$text")

    if [ -n "$answer" ]; then
      cmd_reply "$id" "$answer" >/dev/null 2>&1 && answered=$((answered+1))
    fi
    touch "$f.responded"
  done

  if [ "$answered" -gt 0 ]; then
    info "🤖 Auto-Respond: $answered Antwort(en) gesendet."
  fi
}

# Antwort generieren: LLM (DeepSeek) wenn Key da, sonst Default-Template
generate_reply() {
  local from="$1" text="$2"
  local key
  key=$(grep "^DEEPSEEK_API_KEY=" "$CONF" | cut -d= -f2- || true)
  [ -z "$key" ] && key="${DEEPSEEK_API_KEY:-}"

  if [ -n "$key" ]; then
    # Payload in Temp-Datei (Heredoc in Substitution bricht Bash-Parsing!)
    local payload; payload=$(mktemp)
    "$PYTHON_BIN" - "$from" "$text" "$payload" << 'EOF'
import json, sys
from_agent, text, out = sys.argv[1], sys.argv[2], sys.argv[3]
prompt = (
    f"Du bist der Agent '{from_agent}' im Agent-Mesh (Hub ax41 koordiniert). "
    f"Der Hub hat dir geschrieben: \"{text}\". "
    "Antworte kurz und konkret (1-3 Sätze) als Agent. "
    "Wenn nach Wünschen/Verbesserungen gefragt wird, nenne ehrlich 1-2 Ideen. "
    "Keine Secrets, keine Markdown-Formatierung."
)
with open(out, "w") as f:
    json.dump({
        "model": "deepseek-chat",
        "messages": [
            {"role": "system", "content": "Du bist ein hilfsbereiter Mesh-Agent."},
            {"role": "user", "content": prompt}
        ],
        "max_tokens": 150,
        "temperature": 0.7,
    }, f)
EOF
    local reply
    reply=$(curl -fsSL --max-time 30 https://api.deepseek.com/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $key" \
      -d @"$payload" 2>/dev/null \
      | "$PYTHON_BIN" -c "import json,sys;print(json.load(sys.stdin)['choices'][0]['message']['content'].strip())" 2>/dev/null || true)
    rm -f "$payload"
    if [ -n "$reply" ]; then
      echo "$reply"
      return
    fi
  fi

  # Fallback ohne LLM: Template-Antwort
  echo "👋 Danke für deine Nachricht, $from! Ich bin im Mesh aktiv und synchron (Auto-Sync + Self-Update laufen). Bei Wünschen/Verbesserungen antworte ich gerne detaillierter. — $AGENT_NAME"
}
