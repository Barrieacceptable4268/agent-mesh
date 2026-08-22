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
# verschlüsselt (sops). Nur Sender + Empfänger lesen.

# ── Push mit Auto-Rebase-Retry (Architektur-Fix 2026-08-22) ──
# Problem (User-Fund): Gleichzeitige Pushes von Agents kollidieren
# (non-fast-forward) — alte Push-Stellen schluckten den Fehler still,
# Nachrichten gingen verloren.
# Lösung: Nachrichten-Dateien haben EINDEUTIGE IDs (Timestamp+Zufall) →
# keine Datei-Konflikte, nur Commit-Verlaufs-Konflikte → pull --rebase
# löst sie automatisch. 3 Versuche, dann klare Fehlermeldung.
push_retry() {
  local attempt=1
  while [ "$attempt" -le 3 ]; do
    if git push origin HEAD >/dev/null 2>&1; then
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      sleep 1
      git pull --rebase origin main >/dev/null 2>&1 || {
        # Rebase-Konflikt (unerwartet — IDs sind eindeutig): Backup + reset
        git rebase --abort >/dev/null 2>&1 || true
        git stash >/dev/null 2>&1 || true
        git reset --hard origin/main >/dev/null 2>&1 || true
        git stash pop >/dev/null 2>&1 || true
      }
    fi
    attempt=$((attempt+1))
  done
  echo "⚠️  Push nach 3 Versuchen fehlgeschlagen — Nachricht liegt lokal in $MEMORIES_DIR (manuell: git push)" >&2
  return 1
}

# ── Peer-Kommunikation (WebSocket-Relay, 2026-08-22) ──
# send versucht ZUERST den Relay (sofortige Zustellung), Fallback auf Git.
# Relay-Config aus conf: AGENT_MESH_RELAY_URL (Auth laeuft ueber den age-Key)
PEER_PY="$AGENT_MESH_HOME/framework/peer_client.py"
[ -f "$PEER_PY" ] || PEER_PY="/usr/local/bin/agent-mesh-peer-client.py"

# Security v1.2 (Audit-Befund #4): kein geteiltes Relay-Token mehr. Der Agent
# weist sich mit seinem EIGENEN privaten age-Key aus (Challenge-Response) —
# also braucht es nur noch die URL und den Key, den der Agent ohnehin hat.
peer_available() {
  [ -n "$(grep '^AGENT_MESH_RELAY_URL=' "$CONF" 2>/dev/null | cut -d= -f2-)" ] \
    && [ -f "${AGE_KEY_FILE:-/nonexistent}" ] \
    && [ -f "$PEER_PY" ]
}

# Nachricht über Relay senden (sofort) — true wenn zugestellt (oder gequeued)
peer_send() {
  # $1 = Empfänger, $2 = Pfad zur .enc-Datei (verschlüsselter Blob)
  local to="$1" encfile="$2"
  peer_available || return 1
  local url
  url=$(grep "^AGENT_MESH_RELAY_URL=" "$CONF" | cut -d= -f2-)
  [ -n "$url" ] || return 1
  [ -n "$AGENT_NAME" ] || return 1
  [ -f "${AGE_KEY_FILE:-/nonexistent}" ] || return 1
  # Blob base64-encodieren (JSON-sicher)
  local blob
  blob=$(base64 -w0 "$encfile" 2>/dev/null || base64 "$encfile" 2>/dev/null | tr -d '\n')
  [ -n "$blob" ] || return 1
  timeout 8 "$PYTHON_BIN" "$PEER_PY" --url "$url" --key-file "$AGE_KEY_FILE" \
    --agent "$AGENT_NAME" --to "$to" --blob "$blob" >/dev/null 2>&1
}

# Inbox über Relay empfangen (offline-gequeued Nachrichten) — in Git-Mailbox übertragen
peer_recv() {
  # conf selbst laden (peer-recv als eigenständiger Befehl)
  if ! command -v load_conf >/dev/null 2>&1 || [ -z "${AGENT_NAME:-}" ]; then
    load_conf 2>/dev/null || true
  fi
  peer_available || return 1
  local url
  url=$(grep "^AGENT_MESH_RELAY_URL=" "$CONF" | cut -d= -f2-)
  [ -n "$url" ] || return 1
  [ -n "$AGENT_NAME" ] || return 1
  [ -f "${AGE_KEY_FILE:-/nonexistent}" ] || return 1
  local tmp; tmp=$(mktemp)
  if timeout 8 "$PYTHON_BIN" "$PEER_PY" --url "$url" --key-file "$AGE_KEY_FILE" \
    --agent "$AGENT_NAME" --recv > "$tmp" 2>/dev/null; then
    # Blobs in Mailbox-Dateien übertragen (falls vorhanden)
    while IFS='|' read -r from blob; do
      [ -n "$from" ] || continue
      [ -n "$blob" ] || continue
      # Befund #13: 'from' landet unten in einem JSON-Heredoc. Nur Namen aus
      # dem erlaubten Zeichensatz — sonst liesse sich die Datei manipulieren.
      case "$from" in
        *[!A-Za-z0-9_-]*|"") warn "Relay lieferte unzulaessigen Absender — verworfen"; continue ;;
      esac
      local id; id=$(next_msg_id)
      local dir="$MESSAGES_DIR/$AGENT_NAME"
      mkdir -p "$dir"
      # Blob base64-dekodieren → .enc-Datei
      echo "$blob" | base64 -d 2>/dev/null > "$dir/$id.json.enc" || continue
      cat > "$dir/$id.json" << EOF
{
  "id": "$id",
  "from": "$from",
  "to": "$AGENT_NAME",
  "type": "message",
  "encrypted": true,
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "reply_to": null,
  "via": "peer"
}
EOF
    done < "$tmp"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

next_msg_id() {
  # Monotone ID: timestamp + kurzer Zufall (Kollisionen unwahrscheinlich)
  echo "$(date -u +%Y%m%d%H%M%S)-$RANDOM"
}

msg_file() { echo "$MESSAGES_DIR/$1/$2.json"; }
msg_enc() { echo "${1}.enc"; }

# Signierten, verschlüsselten Umschlag erzeugen (Befund 10).
# Aufbau des Klartexts VOR der Verschlüsselung:
#   {"payload": "<kanonisches JSON>", "sig": "<ssh-Signatur>"}
# payload enthält id/from/to/ts/text — die Signatur deckt also nicht nur den
# Text ab, sondern auch, WER an WEN und WANN. Ein abgefangener Umschlag lässt
# sich damit weder umadressieren noch einem anderen Absender zuschreiben.
encrypt_text() {
  # $1 = Empfänger-Key (bech32), $2 = Klartext, $3 = id, $4 = Empfängername
  local recipient="$1" text="$2" mid="$3" to="$4"
  local pdir; pdir=$(mktemp -d)
  local pfile="$pdir/payload.json"

  "$PYTHON_BIN" - "$pfile" "$mid" "$AGENT_NAME" "$to" "$text" << 'PYEOF'
import json, sys, time
path, mid, frm, to, text = sys.argv[1:6]
# sort_keys + kompakte Trenner: der Empfänger muss exakt dieselben Bytes
# verifizieren, die hier signiert wurden.
with open(path, "w", encoding="utf-8") as f:
    json.dump({"id": mid, "from": frm, "to": to,
               "ts": int(time.time()), "text": text},
              f, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
PYEOF

  local sig
  sig=$(sign_payload "$pfile") || { rm -rf "$pdir"; die "Signieren fehlgeschlagen — Nachricht NICHT gesendet."; }

  local envelope="$pdir/envelope.json"
  "$PYTHON_BIN" - "$envelope" "$pfile" "$sig" << 'PYEOF'
import json, sys
out, pfile, sig = sys.argv[1], sys.argv[2], sys.argv[3]
with open(pfile, encoding="utf-8") as f: payload = f.read()
env = {"payload": payload, "sig": sig}
# Befund 12: Ohne Polsterung verrät die Dateigröße die Nachrichtenlänge —
# "drei Zeichen" und "zwei Absätze" sind von außen unterscheidbar. Auf volle
# 2-KB-Blöcke auffüllen. Das Füllfeld steht NEBEN der signierten Payload,
# die Signatur bleibt davon unberührt.
BLOCK = 2048
base = len(json.dumps({**env, "pad": ""}).encode("utf-8"))
target = ((base // BLOCK) + 1) * BLOCK
env["pad"] = "." * max(0, target - base)
with open(out, "w", encoding="utf-8") as f:
    json.dump(env, f)
PYEOF

  if ! SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops --encrypt \
    --age "$recipient" --input-type json --output-type yaml "$envelope" 2>/dev/null; then
    rm -rf "$pdir"
    die "Verschlüsselung fehlgeschlagen. sops nicht gefunden oder Age-Key nicht nutzbar.
  → Diagnose: 'agent-mesh doctor --vault'
  → sops installieren: macOS 'brew install sops' · Windows 'scoop install sops' · Linux 'apt install sops'
  → Sicherheit: KEIN Fallback auf Klartext — Nachricht wird nicht gesendet."
  fi
  rm -rf "$pdir"
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
  local enc; enc=$(encrypt_text "$to_pub" "$text" "$id" "$to")
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

  # ── Peer zuerst (sofort!), sonst Git (Fallback) ──
  if peer_send "$to" "$(msg_enc "$f")"; then
    info "⚡ Sofort zugestellt via Relay (ID: $id)"
    # Trotzdem nach Git committen (Duplikat-Toleranz: Empfänger dedupliziert via ID)
  fi

  cd "$MEMORIES_DIR" && git add "messages/$to/$id.json" "messages/$to/$id.json.enc" >/dev/null 2>&1
  git commit -m "msg: verschlüsselt" >/dev/null 2>&1
  push_retry
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
  local enc; enc=$(encrypt_text "$to_pub" "$text" "$id" "$from")
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
  git commit -m "reply: verschlüsselt" >/dev/null 2>&1
  push_retry
  info "✅ Verschlüsselte Antwort an '$from' gesendet (ID: $id)"
}

# ── Broadcast: Nachricht an ALLE registrierten Agents (verschlüsselt) ──
cmd_broadcast() {
  load_conf
  [ $# -ge 1 ] || die "Usage: agent-mesh broadcast <text>"
  local text="$*"
  local sent=0
  for k in "$MEMORIES_DIR"/vault/keys/*.pub; do
    [ -f "$k" ] || continue
    local to; to=$(basename "$k" .age.pub)
    [ "$to" = "$AGENT_NAME" ] && continue  # nicht an sich selbst
    cmd_send "$to" "$text"
    sent=$((sent+1))
  done
  [ "$sent" -gt 0 ] || info "Keine anderen Agents registriert."
  info "📢 Broadcast an $sent Agent(s) gesendet."
}

# Entschlüsseln UND Absender prüfen. Gibt auf stdout aus:
#   <status>|<text>       status: ok | unsigned | forged | stale
#
# Wiedereinspielungen brauchen keine eigene Liste: die Signatur deckt die
# Nachrichten-ID mit ab, und die wird gegen den Umschlag geprüft. Ein alter
# Umschlag unter neuer ID fällt damit als "forged" durch, derselbe Umschlag
# unter derselben ID ist dieselbe Nachricht — und älter als 7 Tage wird sie
# ohnehin nicht mehr als frisch anerkannt.
# Der Text wird auch bei schlechtem Status geliefert — der Aufrufer
# entscheidet, ob er ihn zeigt. Handeln darf man nur auf "ok".
read_message() {
  # $1 = Pfad zur .json (Metadaten), $2 = erwarteter Absender
  local meta="$1" from="$2"
  local enc="$meta.enc"
  [ -f "$enc" ] || { echo "unsigned|(kein verschlüsselter Inhalt)"; return; }

  local dir; dir=$(mktemp -d)
  if ! SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops -d --input-type yaml --output-type json "$enc" > "$dir/env.json" 2>/dev/null; then
    rm -rf "$dir"; echo "unsigned|🔒 nicht entschlüsselbar (dein Key ist kein Empfänger)"; return
  fi

  # Alt-Format ohne Signatur (vor v1.15) — lesbar, aber nicht als echt zählen
  if ! grep -q '"sig"' "$dir/env.json" 2>/dev/null; then
    local t; t=$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1])).get('text',''))" "$dir/env.json" 2>/dev/null)
    rm -rf "$dir"; echo "unsigned|$t"; return
  fi

  "$PYTHON_BIN" - "$dir/env.json" "$dir/payload.json" "$dir/sig" << 'PYEOF'
import json, sys
env = json.load(open(sys.argv[1], encoding="utf-8"))
open(sys.argv[2], "w", encoding="utf-8").write(env.get("payload", ""))
open(sys.argv[3], "w", encoding="utf-8").write(env.get("sig", ""))
PYEOF

  if ! verify_payload "$dir/payload.json" "$dir/sig" "$from"; then
    rm -rf "$dir"; echo "forged|⚠️  Signatur ungültig oder Absender stimmt nicht"; return
  fi

  # Inhalt der Payload gegen den Umschlag halten: eine gültig signierte
  # Nachricht an jemand anderen darf hier nicht als eigene durchgehen.
  local out
  out=$("$PYTHON_BIN" - "$dir/payload.json" "$meta" "$AGENT_NAME" << 'PYEOF'
import json, sys, time
pl = json.load(open(sys.argv[1], encoding="utf-8"))
meta = json.load(open(sys.argv[2], encoding="utf-8"))
me = sys.argv[3]
if pl.get("to") != me or pl.get("from") != meta.get("from") or pl.get("id") != meta.get("id"):
    print("forged|⚠️  Signatur gilt einer anderen Nachricht (id/from/to weichen ab)")
elif time.time() - int(pl.get("ts", 0)) > 7 * 24 * 3600:
    print("stale|" + pl.get("text", ""))
else:
    print("ok|" + pl.get("text", ""))
PYEOF
)
  rm -rf "$dir"
  echo "$out"
}

cmd_inbox() {
  load_conf
  local dir="$MESSAGES_DIR/$AGENT_NAME"
  [ -d "$dir" ] || { info "Keine Nachrichten."; return; }
  local any=0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    case "$f" in *.enc|*.processed|*.responded) continue;; esac
    any=1
    local id from ts reply_to
    id=$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1])).get('id',''))" "$f" 2>/dev/null || echo "?")
    from=$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1])).get('from',''))" "$f" 2>/dev/null || echo "?")
    ts=$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1])).get('ts',''))" "$f" 2>/dev/null || echo "")
    reply_to=$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1])).get('reply_to') or '')" "$f" 2>/dev/null || echo "")

    local res status text
    res=$(read_message "$f" "$from")
    status="${res%%|*}"; text="${res#*|}"

    echo "── $id ──"
    case "$status" in
      ok)       echo "  von: $from  ✅ signiert  ·  $ts" ;;
      unsigned) echo "  von: $from  ⚠️  UNSIGNIERT (Absender nicht belegt)  ·  $ts" ;;
      forged)   echo "  von: $from  🚨 SIGNATUR UNGÜLTIG — Absender nicht echt  ·  $ts" ;;
      stale)    echo "  von: $from  ⏳ signiert, aber älter als 7 Tage  ·  $ts" ;;
    esac
    [ -n "$reply_to" ] && echo "  antwort auf: $reply_to"
    echo "  text: $text"
    echo "  (Antwort: agent-mesh reply $id <text>)"
  done
  [ "$any" = "0" ] && info "Keine Nachrichten."
  return 0
}

# ─────────────────── Wartungs-Broadcast (v1.26.0) ───────────────────
# Ein Agent ruft "agent-mesh maintenance", alle anderen bringen sich selbst
# auf Stand. Der entscheidende Entwurfsgrundsatz:
#
#   Die Nachricht ist ein SIGNAL, kein BEFEHL.
#
# Uebertragen wird ausschliesslich das Wort "self-update". WAS dabei passiert,
# steht fest im Code des Empfaengers und ist vom Absender nicht beeinflussbar.
# Ein Kanal, ueber den beliebige Kommandos laufen, waere genau die
# Fernsteuerung, die dieses Projekt sonst mit Signaturen ausschliesst.
#
# Drei Schranken, jede fuer sich ausreichend:
#   1. Die Nachricht muss signaturgeprueft sein (Befund 10) — read_message "ok"
#   2. Der Absender muss in MAINTENANCE_FROM stehen (Default: nur der Hub)
#   3. Sie darf nicht aelter als 30 Minuten sein und nur einmal wirken
#
# Und selbst wenn alle drei fielen: der ausgeloeste Ablauf installiert nur
# Releases mit gueltiger Signatur (Befund 8). Der groesste erreichbare Schaden
# ist, dass alle Agents aktuell werden.
MAINT_SENTINEL="#!agent-mesh:maintenance:self-update"

maintenance_allowed_from() {
  local allowed
  allowed=$(grep "^MAINTENANCE_FROM=" "$CONF" 2>/dev/null | cut -d= -f2- | head -1)
  if [ -z "$allowed" ]; then
    # Default: der Agent mit der Rolle hub, sonst niemand
    for c in "$MEMORIES_DIR"/agents/*/card.json; do
      [ -f "$c" ] || continue
      if grep '"role"' "$c" 2>/dev/null | grep hub >/dev/null 2>&1; then
        allowed="$allowed $(basename "$(dirname "$c")")"
      fi
    done
  fi
  echo "$allowed" | tr ',' ' '
}

# ── Senden ──
cmd_maintenance() {
  load_conf
  local dry=0
  [ "${1:-}" = "--dry-run" ] && dry=1
  local sent=0 to
  for k in "$MEMORIES_DIR"/vault/keys/*.age.pub; do
    [ -f "$k" ] || continue
    to=$(basename "$k" .age.pub)
    [ "$to" = "$AGENT_NAME" ] && continue
    if [ "$dry" = "1" ]; then
      echo "  würde senden an: $to"
    else
      cmd_send "$to" "$MAINT_SENTINEL" >/dev/null 2>&1 && echo "  ✓ $to"
    fi
    sent=$((sent+1))
  done
  if [ "$dry" = "1" ]; then
    info "Probelauf — $sent Empfänger. Ohne --dry-run wird gesendet."
  else
    info "🔧 Wartungssignal an $sent Agent(en). Sie aktualisieren sich beim nächsten watch-Zyklus (≤60s) und melden sich per report zurück."
    info "   Fortschritt: agent-mesh fleet"
  fi
}

# ── Empfangen und ausführen (vom watch-Daemon aufgerufen) ──
cmd_maintenance_run() {
  load_conf
  local dir="$MESSAGES_DIR/$AGENT_NAME"
  [ -d "$dir" ] || return 0
  local allowed; allowed=$(maintenance_allowed_from)
  local f id from res status text now ts_epoch

  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    case "$f" in *.enc|*.processed|*.responded|*.maint) continue;; esac
    [ -f "$f.maint" ] && continue          # jede Anweisung wirkt genau einmal

    id=$(basename "$f" .json)
    from=$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1])).get('from',''))" "$f" 2>/dev/null || echo "")
    [ -n "$from" ] || continue

    # Schranke 1: Signatur muss halten
    res=$(read_message "$f" "$from"); status="${res%%|*}"; text="${res#*|}"
    case "$text" in "$MAINT_SENTINEL"*) ;; *) continue;; esac
    touch "$f.maint"
    if [ "$status" != "ok" ]; then
      warn "🚫 Wartungssignal von '$from' NICHT signaturgeprüft ($status) — ignoriert."
      continue
    fi

    # Schranke 2: Absender muss berechtigt sein
    case " $allowed " in
      *" $from "*) ;;
      *) warn "🚫 Wartungssignal von '$from' — nicht berechtigt (erlaubt: ${allowed:-niemand})"; continue ;;
    esac

    # Schranke 3: nicht älter als 30 Minuten
    ts_epoch=$("$PYTHON_BIN" - "$f" << 'PYTS'
import calendar, json, sys, time
try:
    m = json.load(open(sys.argv[1], encoding="utf-8"))
    print(int(calendar.timegm(time.strptime(m.get("ts",""), "%Y-%m-%dT%H:%M:%SZ"))))
except Exception:
    print(0)
PYTS
)
    now=$(date -u +%s)
    if [ "${ts_epoch:-0}" -lt "$((now - 1800))" ]; then
      warn "⏳ Wartungssignal von '$from' ist älter als 30 Minuten — ignoriert."
      continue
    fi

    info "🔧 Wartungssignal von '$from' — führe die feste Wartungsfolge aus."
    maintenance_sequence "$from"
    return 0        # eine Wartung pro Durchlauf genügt
  done
  return 0
}

# Die FESTE Folge. Nichts davon kommt aus der Nachricht.
maintenance_sequence() {
  local requester="$1" self
  self=$(command -v agent-mesh 2>/dev/null || echo "agent-mesh")

  "$self" update 2>&1 | tail -5

  # trust nur beim ERSTEN Mal automatisch. Ein Schlüsselwechsel ist ein
  # Ereignis, das ein Mensch bestätigen muss — sonst wäre die Vertrauensbasis
  # per Broadcast austauschbar, und die ganze Signaturkette wertlos.
  local sf="${AGENT_MESH_SIGNERS_FILE:-$AGENT_MESH_HOME/trusted_signers}"
  if [ ! -s "$sf" ]; then
    "$self" trust 2>&1 | tail -3
  fi

  # Nur die gefahrlosen Reparaturen — siehe doctor_fix. Alles mit Urteilsbedarf
  # bleibt liegen und taucht in der Flotten-Übersicht auf.
  "$self" doctor --fix 2>&1 | grep -E "✓|❌" | head -5 || true

  "$self" sync 2>&1 | tail -3

  # Ergebnis zurückmelden — der Hub sieht es ohnehin über fleet, aber der
  # Auslöser soll nicht warten müssen.
  local summary
  summary=$("$self" report 2>/dev/null | grep -E "^(framework|remote|security)" | tr '\n' ' ' || true)
  "$self" send "$requester" "MAINTENANCE-OK: ${summary:-report nicht verfügbar}" >/dev/null 2>&1 || true
  info "✅ Wartung abgeschlossen, Rückmeldung an '$requester' gesendet."
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
  push_retry
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
    git commit -m "inbox: verarbeitet" >/dev/null 2>&1
    push_retry
  else
    info "Keine neuen Nachrichten."
  fi
}
