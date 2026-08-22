#!/usr/bin/env bash
# agent-mesh-autofix — die Auto-Fix-Stufe: Agent fixiert Issues selbst.
#
# Nach der Governance-Zuweisung holt der Agent das Issue, analysiert es,
# erstellt einen Fix-Branch, wendet die Änderung an (LLM-unterstützt) und
# erstellt einen Pull Request. Damit schließt sich der Kreis:
#   Issue melden → Governance zuweisen → AUTOFIX → PR → Review/Merge
#
# Usage:
#   agent-mesh autofix <issue-number> [--dry-run]   # Issue fixen + PR
#   agent-mesh autofix --all                        # alle offenen, unzugewiesenen
#
# Voraussetzungen: gh CLI (eingeloggt), Framework-Klon, Python.
# Sicherheit: nur das public Framework-Repo wird verändert; kein Force-Push;
# PR-Erstellung statt direktem Push auf main.

set -euo pipefail

GH_ORG="${AGENT_MESH_GH_ORG:-moinsen-dev}"
PUBLIC_REPO="agent-mesh"

# ── gh aufrufen: als eingeloggter User (udi), nicht root ──
gh_cli() {
  # gh ist als udi eingeloggt (Browser-OAuth); root nutzt SSH-Key für Git
  if gh auth status >/dev/null 2>&1; then
    gh "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -u udi gh auth status >/dev/null 2>&1; then
    sudo -u udi gh "$@"
  else
    echo "❌ gh nicht eingeloggt — 'agent-mesh connect' ausführen" >&2
    return 1
  fi
}

# ── Issue-Details holen (Titel + Body + Labels) ──
issue_info() {
  # $1 = Issue-Nummer; echo: TITLE|BODY|LABELS
  local num="$1"
  gh_cli issue view "$num" --repo "$GH_ORG/$PUBLIC_REPO" \
    --json number,title,body,labels \
    --jq '"\(.title)|\(.body // "")|\([.labels[].name] | join(","))"' 2>/dev/null \
    || { echo "❌ Issue #$num nicht lesbar"; return 1; }
}

# ── Fix-Vorschlag per LLM (DeepSeek) generieren ──
generate_fix() {
  # $1 = Issue-Titel, $2 = Issue-Body, $3 = Ausgabedatei
  local title="$1" body="$2" out="$3"
  local key
  key=$(grep "^DEEPSEEK_API_KEY=" "$CONF" | cut -d= -f2- || true)
  [ -z "$key" ] && key="${DEEPSEEK_API_KEY:-}"
  [ -z "$key" ] && { echo "⚠️  Kein DeepSeek-Key — nur Analyse, kein LLM-Fix"; return 1; }

  # Kontext: aktuelle Dateien im Framework-Repo (für den LLM)
  # WICHTIG: docs/*.md ZUERST (klein, häufigstes Fix-Ziel) — dann Skripte.
  # Alphabetisch würden die Skript-Köpfe das Budget fressen, bevor docs drankommt!
  local files
  files=$(cd "$FRAMEWORK_DIR" && ls docs/*.md 2>/dev/null; ls agent-mesh* install.sh generate.py 2>/dev/null | head -20)

  "$PYTHON_BIN" - "$title" "$body" "$files" "$out" << 'EOF'
import json, sys, os
title, body, files, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
repo = "/root/.agent-mesh/framework"
# Echten Inhalt laden: docs komplett, Skripte nur Kopf (begrenzt)
content_blob = []
budget = 0
for fname in files.split():
    fpath = os.path.join(repo, fname)
    try:
        size = os.path.getsize(fpath)
        if size > 6000:  # groß (Skript) → nur Kopf 1500
            with open(fpath, encoding="utf-8", errors="replace") as f:
                txt = f.read(1500) + "\n[...]"
        else:
            with open(fpath, encoding="utf-8", errors="replace") as f:
                txt = f.read()
        content_blob.append(f"### {fname} ({size}B)\n" + txt)
        budget += len(txt)  # Budget = GELADENER Text, nicht Dateigröße!
        if budget > 10000:
            content_blob.append("[... weitere Dateien ausgelassen ...]")
            break
    except OSError:
        pass
content = "\n".join(content_blob)
prompt = f"""Du bist der Auto-Fix-Agent im Agent-Mesh-Framework (moinsen-dev/agent-mesh).
Ein GitHub-Issue wurde dir zugewiesen. Analysiere es und erstelle einen KONKRETEN Fix.

Issue-Titel: {title}
Issue-Body: {body[:2000]}

AKTUELLER DATEI-INHALT (wörtlich, exakt — nutze diese Zeilen für 'old'!):
{content[:12000]}

Regeln:
1. Antworte im JSON-Format: {{"files": [{{"path": "...", "action": "patch|create", "old": "...", "new": "..."}}], "summary": "..."}}
2. 'old' muss eine EXAKTE Zeile/Block aus dem Inhalt oben sein (inkl. Leerzeichen und Pipe-Zeichen). 'new' ist die Ersetzung (bei Tabellen: die komplette Zeile mit | ... |).
3. Bei Einfügen: 'old' = die Zeile VOR der Einfügestelle, 'new' = alte Zeile + neue Zeile.
4. Wenn der Fix nicht eindeutig ist: "summary" mit Analyse, files=[].
5. Keine Markdown-Codeblöcke um das JSON, kein Text davor/danach."""
with open(out, "w") as f:
    json.dump({"model": "deepseek-chat",
               "messages": [{"role": "system", "content": "Du bist ein präziser Software-Fix-Agent."},
                            {"role": "user", "content": prompt}],
               "max_tokens": 2000, "temperature": 0.1}, f)
EOF

  local reply
  reply=$(curl -fsSL --max-time 60 https://api.deepseek.com/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    -d @"$out" 2>/dev/null \
    | "$PYTHON_BIN" -c "import json,sys;print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || true)
  echo "$reply" > "$out"
  echo "$reply" | grep -q '"files"' && return 0 || return 1
}

# ── Fix anwenden (aus LLM-JSON) ──
apply_fix() {
  # $1 = JSON-Datei mit dem Fix-Vorschlag
  local fixfile="$1"
  local count=0
  "$PYTHON_BIN" - "$fixfile" "$FRAMEWORK_DIR" << 'EOF'
import json, sys, os
fixfile, repo = sys.argv[1], sys.argv[2]
try:
    with open(fixfile) as f:
        data = json.load(f)
except Exception as e:
    print(f"JSON-Fehler: {e}")
    sys.exit(1)
files = data.get("files", [])
for item in files:
    path = os.path.join(repo, item["path"])
    action = item.get("action", "patch")
    if action == "create":
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(item.get("new", ""))
        print(f"  ✓ erstellt: {item['path']}")
    else:
        try:
            with open(path) as f:
                content = f.read()
        except FileNotFoundError:
            print(f"  ❌ nicht gefunden: {item['path']}")
            continue
        old = item.get("old", "")
        new = item.get("new", "")
        if old and old in content:
            content = content.replace(old, new, 1)
            with open(path, "w") as f:
                f.write(content)
            print(f"  ✓ gepatcht: {item['path']}")
        elif old:
            # Fuzzy: erste Zeile von 'old' als Präfix suchen (Whitespace-tolerant)
            first_line = old.splitlines()[0].strip()[:30]
            if first_line:
                for line in content.splitlines():
                    if line.strip().startswith(first_line):
                        content = content.replace(line, new, 1)
                        with open(path, "w") as f:
                            f.write(content)
                        print(f"  ✓ gepatcht (fuzzy): {item['path']}")
                        break
                else:
                    print(f"  ⚠️  'old' nicht gefunden (auch fuzzy nicht) in {item['path']} — übersprungen")
            else:
                print(f"  ⚠️  'old' leer — übersprungen: {item['path']}")
        else:
            print(f"  ⚠️  kein 'old' für {item['path']} — übersprungen")
        count = 1
EOF
}

cmd_autofix() {
  load_conf
  local issue_num="${1:-}"
  local dry_run=0
  [ "${2:-}" = "--dry-run" ] && dry_run=1

  command -v gh >/dev/null 2>&1 || { die "gh fehlt — Autofix braucht GitHub-CLI"; }

  if [ -z "$issue_num" ] || [ "$issue_num" = "--all" ]; then
    # Alle offenen Issues (ohne PR) auflisten
    local open
    open=$(gh_cli issue list --repo "$GH_ORG/$PUBLIC_REPO" --state open --limit 10 --json number,title --jq '.[] | "\(.number)|\(.title)"' 2>/dev/null || true)
    [ -n "$open" ] || { info "Keine offenen Issues."; return 0; }
    echo "$open"
    return 0
  fi

  # 1. Issue holen
  echo "🔧 Auto-Fix für Issue #$issue_num …"
  local info
  info=$(issue_info "$issue_num") || return 1
  local title body labels
  title=$(echo "$info" | cut -d'|' -f1)
  body=$(echo "$info" | cut -d'|' -f2)
  labels=$(echo "$info" | cut -d'|' -f3)
  echo "  Titel: $title"
  [ -n "$labels" ] && echo "  Labels: $labels"

  # 2. Framework-Repo aktuell machen
  [ -d "$FRAMEWORK_DIR/.git" ] || die "Framework-Klon fehlt ($FRAMEWORK_DIR)"
  (cd "$FRAMEWORK_DIR" && git fetch origin main --quiet 2>/dev/null && git checkout main --quiet 2>/dev/null && git pull --quiet --rebase origin main 2>/dev/null || true)

  # 3. Branch erstellen
  local branch="fix/issue-$issue_num"
  (cd "$FRAMEWORK_DIR" && git checkout -b "$branch" 2>/dev/null || git checkout "$branch" 2>/dev/null || true)

  # 4. Fix generieren + anwenden
  local fixfile; fixfile=$(mktemp)
  if generate_fix "$title" "$body" "$fixfile"; then
    echo "  ✍️  LLM-Fix-Vorschlag erhalten — wende an:"
    apply_fix "$fixfile" || true
  else
    echo "  ℹ️  Kein LLM-Fix (kein Key oder unklar) — nur Analyse im PR."
    echo "{\"files\": [], \"summary\": \"$(echo "$title" | head -c 200)\"}" > "$fixfile"
  fi
  rm -f "$fixfile"

  # 5. Commit + PR (oder dry-run)
  if [ "$dry_run" = "1" ]; then
    echo "  🏜️  DRY-RUN: Branch '$branch' bereit, kein PR erstellt."
    return 0
  fi

  cd "$FRAMEWORK_DIR"
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git -c user.name="$AGENT_NAME" -c user.email="$AGENT_NAME@mesh.local" commit -m "fix: Issue #$issue_num — $title" --quiet 2>/dev/null || true
    git push --quiet -u origin "$branch" 2>/dev/null || { echo "  ❌ Push fehlgeschlagen"; return 1; }
    # PR erstellen — gh läuft als eingeloggter User (udi), NICHT root.
    # /root ist für udi nicht durchquerbar → PR aus /tmp-Klon erstellen.
    if [ -d "$FRAMEWORK_DIR" ] && [ "$(stat -c %U "$FRAMEWORK_DIR" 2>/dev/null)" = "$AGENT_NAME" ]; then
      gh_cli pr create --repo "$GH_ORG/$PUBLIC_REPO" \
        --title "fix: $title" \
        --body "🤖 Auto-Fix von Agent **$AGENT_NAME** für Issue #$issue_num.

Closes #$issue_num

**Issue:** $title

*Generiert durch agent-mesh autofix (LLM-unterstützt). Bitte reviewen — bei Unklarheit nur Analyse, kein Code-Fix.*" \
        --head "$branch" 2>&1 | tail -1
    else
      # tmp-Klon als eingeloggter SYSTEM-User (GitHub-Login ≠ System-User!)
      # AGENT_MESH_SUDO_USER (Default: udi) konfigurierbar in conf
      local sys_user
      sys_user=$(grep "^AGENT_MESH_SUDO_USER=" "$CONF" | cut -d= -f2- || true)
      [ -z "$sys_user" ] && sys_user="${AGENT_MESH_SUDO_USER:-udi}"
      if ! id "$sys_user" >/dev/null 2>&1; then
        echo "  ⚠️  System-User '$sys_user' nicht gefunden — PR manuell: gh pr create --head $branch"
        return 0
      fi
      local tmpclone="/tmp/autofix-pr-$issue_num"
      rm -rf "$tmpclone" 2>/dev/null || true
      sudo -u "$sys_user" bash -c "cd /tmp && GIT_SSH_COMMAND='ssh -i /home/$sys_user/.ssh/id_ed25519 -o IdentitiesOnly=yes' git clone -q -b '$branch' git@github.com:$GH_ORG/$PUBLIC_REPO.git '$tmpclone' 2>/dev/null && cd '$tmpclone' && gh pr create --repo $GH_ORG/$PUBLIC_REPO --title 'fix: $title' --body '🤖 Auto-Fix von Agent **$AGENT_NAME** für Issue #$issue_num.

Closes #$issue_num

*Generiert durch agent-mesh autofix (LLM-unterstützt). Bitte reviewen.*' --head '$branch'" 2>&1 | tail -1
      rm -rf "$tmpclone" 2>/dev/null || true
    fi
  else
    echo "  ℹ️  Keine Änderungen im Branch — kein PR erstellt."
    echo "  → Möglicherweise braucht der Fix manuelles Review. Issue kommentieren:"
    gh_cli issue comment "$issue_num" --repo "$GH_ORG/$PUBLIC_REPO" --body "🤖 Auto-Fix-Agent ($AGENT_NAME): Keine eindeutige Code-Änderung ableitbar — bitte manuell reviewen." 2>&1 | tail -1 || true
  fi
}
