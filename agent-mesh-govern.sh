#!/usr/bin/env bash
# agent-mesh-govern — Selbst-Verwaltung: verteilt GitHub-Issues an Agents.
#
# Der Hub (oder jeder Agent mit gh-Zugriff) prüft periodisch offene Issues
# im public Repo und weist sie automatisch zu:
#   - Issue-Titel → passender Agent (Stichworte: windows→windows-Agent,
#     mac→mac-Agent, vault/security→Hub, etc.)
#   - Zuweisung per verschlüsselter Mesh-Nachricht (send <agent> ...)
#   - Status wird in .github/governance.md dokumentiert
#
# Usage:
#   agent-mesh govern [--dry-run]     # Issues prüfen + zuweisen
#   agent-mesh govern --list          # nur anzeigen
#
# Als Cron: 0 */6 * * * agent-mesh govern  (alle 6h)

set -euo pipefail

GOV_FILE=".github/governance.md"
GH_ORG="${AGENT_MESH_GH_ORG:-moinsen-dev}"
PUBLIC_REPO="agent-mesh"

# Stichwort → Agent-Zuordnung (anpassbar!)
agent_for_issue() {
  # $1 = Issue-Titel (lowercase)
  local title="$1"
  case "$title" in
    *windows*|*wsl*|*git-bash*|*powershell*|*scheduler*|*schtasks*) echo "nucbox-evo-x2" ;;
    *mac*|*launchd*|*osx*|*m1*|*apple*) echo "dev-docker" ;;
    *macmini*|*mini*) echo "macmini" ;;
    *vault*|*sops*|*age*|*secret*|*encrypt*) echo "ax41" ;;
    *webhook*|*cloudflare*|*tunnel*) echo "ax41" ;;
    *respond*|*broadcast*|*a2a*|*message*) echo "ax41" ;;
    *update*|*self-update*|*version*) echo "ax41" ;;
    *) echo "ax41" ;;  # Default: Hub
  esac
}

cmd_govern() {
  load_conf
  local dry_run=0
  local do_fix=0
  [ "${1:-}" = "--dry-run" ] && dry_run=1
  [ "${1:-}" = "--list" ] && { dry_run=1; }
  [ "${1:-}" = "--fix" ] && do_fix=1

  command -v gh >/dev/null 2>&1 || { warn "gh fehlt — Governance braucht GitHub-CLI"; return 1; }

  # Offene Issues holen (gh_cli — root hat kein gh-Auth, udi schon!)
  local issues
  issues=$(gh_cli issue list --repo "$GH_ORG/$PUBLIC_REPO" --state open --limit 20 --json number,title,labels --jq '.[] | "\(.number)|\(.title)"' 2>/dev/null || true)
  [ -n "$issues" ] || { info "Keine offenen Issues."; return 0; }

  echo "🔧 Agent-Mesh Governance — offene Issues:"
  echo "$issues" | while IFS='|' read -r num title; do
    [ -n "$num" ] || continue
    local lower assignee
    lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')
    assignee=$(agent_for_issue "$lower")

    # Bereits zugewiesen? (governance.md prüfen)
    if [ -f "$MEMORIES_DIR/$GOV_FILE" ] && grep -q "| #$num |" "$MEMORIES_DIR/$GOV_FILE" 2>/dev/null; then
      echo "  #$num $title → $assignee (bereits zugewiesen)"
      continue
    fi

    echo "  #$num $title → $assignee"

    if [ "$dry_run" = "0" ]; then
      # Zuweisung per verschlüsselter Nachricht
      cmd_send "$assignee" "🎯 GITHUB-ISSUE #$num zugewiesen: '$title' (https://github.com/$GH_ORG/$PUBLIC_REPO/issues/$num). Bitte analysieren und Fix als Kommentar/PR beitragen — oder hier zurückmelden. — Governance" >/dev/null 2>&1 || true
      # Dokumentieren
      mkdir -p "$MEMORIES_DIR/.github"
      echo "| #$num | $title | $assignee | $(date -u +%Y-%m-%d) |" >> "$MEMORIES_DIR/$GOV_FILE" 2>/dev/null
    fi

    # ── AUTO-FIX-STUFE: Fix direkt ausführen (Hub hat gh + Key) ──
    if [ "$do_fix" = "1" ] && [ "$dry_run" = "0" ]; then
      echo "  ⚡ Auto-Fix für #$num starten…"
      cmd_autofix "$num" 2>&1 | sed 's/^/    /'
    fi
  done

  # Governance-Datei committen (falls neue Einträge)
  if [ "$dry_run" = "0" ] && [ -f "$MEMORIES_DIR/$GOV_FILE" ]; then
    (cd "$MEMORIES_DIR" && git add .github/governance.md >/dev/null 2>&1 \
      && git commit -m "governance: Issues zugewiesen" >/dev/null 2>&1 \
      && git push origin HEAD >/dev/null 2>&1) || true
    info "✅ Governance-Update gepusht."
  fi
}
