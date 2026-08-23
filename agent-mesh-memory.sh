#!/usr/bin/env bash
# agent-mesh-memory — ein gemeinsames Gedächtnis für den ganzen Verbund.
#
# ── Warum das der richtige Ort für eine Datenbank ist ─────────────────────
#
# Bis hierher war "geteiltes Wissen" das Kopieren von MEMORY.md-Dateien in ein
# Git-Repo. Das hatte zwei Fehler: es kam nie irgendwo an (bis v1.29.0 las es
# niemand), und selbst wenn — eine Datei ist nicht abfragbar. Sechs Agenten
# haben so 19 MB Repo und 11.195 Commits für 6 KB Text erzeugt.
#
# Hermes hat für genau das einen vorgesehenen Steckplatz: `hermes memory` mit
# austauschbaren Providern. Wir bauen ihn nicht nach, wir füllen ihn — mit
# mem0 auf einem eigenen Server. Serverseitige Faktenextraktion, semantische
# Suche, Deduplizierung. Und die Aufteilung passt auf einen Verbund:
#
#     user_id   = der MENSCH        — für alle Agenten derselbe
#     agent_id  = die MASCHINE      — pro Agent verschieden
#
# Damit hat jeder Agent Zugriff auf dasselbe Gedächtnis, und man sieht
# trotzdem, wer was beigetragen hat.
#
# ── Was agent-mesh dabei beiträgt ──
#
# Den schweren Teil: den API-Schlüssel sicher auf sechs Maschinen zu bekommen.
# Das Vault verschlüsselt ihn für BENANNTE Empfänger, pinnt deren Schlüssel und
# behandelt jede Änderung als Ereignis. Hermes liefert den Rest.
#
# Die Topologie entscheidet dabei mit: der Server muss von jedem Agenten
# ERREICHBAR sein, aber kein Agent muss erreichbar sein. Genau deshalb ist ein
# zentrales Gedächtnis für diesen Verbund machbar, während peer-to-peer an den
# Maschinen hinter NAT scheitert.
#
# Usage:
#   agent-mesh memory setup --host <url> [--key <schlüssel>]   (einmal, am Hub)
#   agent-mesh memory join                                     (auf jedem Agenten)
#   agent-mesh memory status
#   agent-mesh memory off

set -euo pipefail

MEM_VAULT_KEY="mesh-memory-key"

hermes_home() { echo "${HERMES_HOME:-$HOME/.hermes}"; }
mesh_memory_conf() { echo "$MEMORIES_DIR/memory.json"; }

# Der Server wird nicht geglaubt, sondern gefragt. Ein Gedächtnis, das nicht
# antwortet, ist schlimmer als keins: der Agent merkt es erst, wenn er etwas
# sucht, und dann sieht es aus, als wüsste er nichts.
mem_probe() {   # mem_probe <host> <key> → 0 wenn der Server den Vertrag erfüllt
  local host="$1" key="$2"
  "$PYTHON_BIN" - "$host" "$key" << 'PYPROBE'
import json, sys, urllib.error, urllib.request

host, key = sys.argv[1].rstrip("/"), sys.argv[2]

def call(method, path, body):
    req = urllib.request.Request(
        host + path, method=method,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 **({"X-API-Key": key} if key else {})})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status, r.read()

try:
    # Genau der Aufruf, den Hermes' SelfHostedBackend macht.
    status, _ = call("POST", "/search", {"query": "agent-mesh probe", "user_id": "agent-mesh-probe"})
except urllib.error.HTTPError as e:
    if e.code in (401, 403):
        print(f"  Server antwortet, weist den Schlüssel aber ab (HTTP {e.code}).")
        sys.exit(2)
    print(f"  Server antwortet mit HTTP {e.code} auf POST /search — kein mem0-Server?")
    sys.exit(3)
except Exception as e:
    print(f"  Nicht erreichbar: {type(e).__name__}: {e}")
    sys.exit(4)
print(f"  POST /search → HTTP {status}")
sys.exit(0)
PYPROBE
}

# ── setup: einmal, von der Maschine aus, die den Server kennt ─────────────
mem_setup() {
  local host="" key=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) host="${2:-}"; shift 2 ;;
      --key)  key="${2:-}";  shift 2 ;;
      *) die "memory setup: unbekannte Option '$1' (agent-mesh memory --help)" ;;
    esac
  done
  [ -n "$host" ] || die "memory setup braucht --host <url> (z.B. https://memory.example.dev)"

  echo "── Server prüfen ──"
  if mem_probe "$host" "$key"; then
    echo "  ✅ $host erfüllt den mem0-Vertrag"
  else
    case "$?" in
      2) die "Der Schlüssel wird abgewiesen — mit --key den richtigen mitgeben." ;;
      *) die "Kein brauchbarer mem0-Server unter $host. Nichts eingetragen." ;;
    esac
  fi

  # Der Schlüssel ist ein Secret und gehört ins Vault — für alle Agenten, die
  # es im Verbund gibt. Der Host ist keiner und darf offen im privaten Repo
  # stehen, damit `join` ihn ohne Rückfrage findet.
  if [ -n "$key" ]; then
    local recipients=""
    for k in "$MEMORIES_DIR"/vault/keys/*.age.pub; do
      [ -f "$k" ] || continue
      recipients="$recipients,$(basename "$k" .age.pub)"
    done
    recipients="${recipients#,}"
    [ -n "$recipients" ] || die "Keine Empfänger im Vault — zuerst: agent-mesh sync"
    echo "── Schlüssel ins Vault, für: $recipients ──"
    cmd_vault_set "$MEM_VAULT_KEY" "$key" --for "$recipients" >/dev/null
    echo "  ✅ als '$MEM_VAULT_KEY' hinterlegt"
  else
    info "Ohne --key: der Server läuft offenbar ohne Authentifizierung."
  fi

  mkdir -p "$(dirname "$(mesh_memory_conf)")"
  "$PYTHON_BIN" - "$(mesh_memory_conf)" "$host" "$GH_OWNER" << 'PYCONF'
import json, sys
path, host, owner = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"provider": "mem0", "host": host, "user_id": owner},
          open(path, "w"), indent=2)
PYCONF
  echo "  ✅ Server im Verbund bekanntgegeben ($(mesh_memory_conf))"
  echo ""
  echo "Jetzt auf JEDEM Agenten:  agent-mesh memory join"
  echo "(Beim nächsten converge findet ihn jeder von selbst.)"
}

# ── join: auf jeder Maschine, verdrahtet den lokalen Hermes ───────────────
mem_join() {
  local hh; hh=$(hermes_home)
  command -v hermes >/dev/null 2>&1 || die "Kein Hermes auf dieser Maschine — nichts zu verdrahten."
  [ -f "$(mesh_memory_conf)" ] || die "Der Verbund kennt noch kein Gedächtnis.
  → einmal am Hub: agent-mesh memory setup --host <url> [--key <schlüssel>]"

  local host owner
  host=$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1])).get('host',''))" "$(mesh_memory_conf)")
  owner=$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1])).get('user_id',''))" "$(mesh_memory_conf)")
  [ -n "$host" ] || die "Im Verbund steht kein Host — 'agent-mesh memory setup' am Hub wiederholen."

  local key=""
  key=$(cmd_vault_get "$MEM_VAULT_KEY" 2>/dev/null || true)

  echo "── Server prüfen, bevor etwas eingetragen wird ──"
  mem_probe "$host" "$key" || die "Nichts eingetragen — der Server antwortet nicht wie erwartet."
  echo "  ✅ erreichbar"

  # mem0.json: Host + Identitäten. mode bleibt der Default — der Backend-Wähler
  # nimmt den selbst gehosteten HTTP-Pfad, SOBALD ein host gesetzt ist;
  # mode=oss wäre die eingebettete Bibliothek und damit etwas anderes.
  "$PYTHON_BIN" - "$hh/mem0.json" "$host" "$owner" "$AGENT_NAME" << 'PYMEM'
import json, os, sys
path, host, owner, agent = sys.argv[1:5]
cfg = {}
if os.path.exists(path):
    try: cfg = json.load(open(path))
    except Exception: cfg = {}
cfg.update({"host": host, "user_id": owner, "agent_id": agent})
tmp = path + ".tmp"
json.dump(cfg, open(tmp, "w"), indent=2)
os.replace(tmp, path)
PYMEM
  echo "  ✓ $hh/mem0.json — user_id=$owner, agent_id=$AGENT_NAME"

  if [ -n "$key" ]; then
    local envf="$hh/.env"
    touch "$envf"; chmod 600 "$envf" 2>/dev/null || true
    # Zeile ersetzen statt anhängen — sonst sammeln sich bei jedem join
    # widersprüchliche MEM0_API_KEY-Zeilen, und welche gilt, hängt vom Leser ab.
    grep -v "^MEM0_API_KEY=" "$envf" > "$envf.tmp" 2>/dev/null || true
    printf 'MEM0_API_KEY=%s\n' "$key" >> "$envf.tmp"
    mv -f "$envf.tmp" "$envf"
    chmod 600 "$envf" 2>/dev/null || true
    echo "  ✓ Schlüssel aus dem Vault in $envf"
  fi

  hermes config set memory.provider mem0 >/dev/null 2>&1 \
    && echo "  ✓ Hermes nutzt ab jetzt mem0" \
    || warn "hermes config set memory.provider mem0 ist gescheitert — von Hand nachziehen."

  echo ""
  mem_status
}

mem_status() {
  local hh; hh=$(hermes_home)
  echo "── Gemeinsames Gedächtnis ──"
  if [ ! -f "$(mesh_memory_conf)" ]; then
    echo "  Verbund:  keiner eingerichtet (agent-mesh memory setup --host <url>)"
    return 0
  fi
  local host owner
  host=$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1])).get('host',''))" "$(mesh_memory_conf)" 2>/dev/null || echo "?")
  owner=$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1])).get('user_id',''))" "$(mesh_memory_conf)" 2>/dev/null || echo "?")
  printf '  %-10s %s\n' "Verbund:" "$host (user_id=$owner)"

  local active=""
  if command -v hermes >/dev/null 2>&1; then
    active=$(hermes config get memory.provider 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
  fi
  if [ "$active" = "mem0" ]; then
    printf '  %-10s %s\n' "Hermes:" "mem0 aktiv"
  else
    printf '  %-10s %s\n' "Hermes:" "${active:-kein externer Provider} — 'agent-mesh memory join' verdrahtet ihn"
  fi

  if [ -f "$hh/mem0.json" ]; then
    local lh la
    lh=$("$PYTHON_BIN" -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('host',''))" "$hh/mem0.json" 2>/dev/null || echo "")
    la=$("$PYTHON_BIN" -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('agent_id',''))" "$hh/mem0.json" 2>/dev/null || echo "")
    printf '  %-10s %s\n' "Lokal:" "agent_id=$la"
    # Zeigt der lokale Eintrag noch woanders hin als der Verbund? Das passiert
    # nach einem Serverwechsel und ist von aussen unsichtbar — der Agent
    # schreibt dann still in ein Gedächtnis, das niemand sonst liest.
    [ -n "$lh" ] && [ "$lh" != "$host" ] && \
      echo "  ⚠️  Lokal steht $lh, der Verbund nutzt $host — 'agent-mesh memory join'"
  fi

  local key=""; key=$(cmd_vault_get "$MEM_VAULT_KEY" 2>/dev/null || true)
  printf '  %-10s ' "Server:"
  if mem_probe "$host" "$key" >/dev/null 2>&1; then echo "antwortet"; else echo "ANTWORTET NICHT"; mem_probe "$host" "$key" || true; fi
}

mem_off() {
  command -v hermes >/dev/null 2>&1 || die "Kein Hermes auf dieser Maschine."
  hermes memory off >/dev/null 2>&1 \
    && echo "✅ Externer Provider abgeschaltet — Hermes nutzt wieder nur MEMORY.md/USER.md." \
    || die "hermes memory off ist gescheitert."
}

cmd_memory() {
  load_conf
  local sub="${1:-status}"
  shift 2>/dev/null || true
  case "$sub" in
    setup)  mem_setup "$@" ;;
    join)   mem_join ;;
    status) mem_status ;;
    off)    mem_off ;;
    *) die "memory: {setup --host <url> [--key <k>]|join|status|off}" ;;
  esac
}
