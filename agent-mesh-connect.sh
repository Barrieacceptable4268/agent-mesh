#!/usr/bin/env bash
# agent-mesh-connect — explizite User-Autorisierung per BROWSER-AUTH.
#
# Idee (User, 2026-08-22): Der Agent fragt aktiv "Darf ich mich mit deinem
# GitHub-Account verknüpfen?" — und die Authentifizierung läuft über den
# BROWSER (OAuth Device-Flow), NICHT über SSH-Keys:
#
#   1. gh CLI prüfen (oder installieren)
#   2. gh auth login --web  →  One-Time-Code + Browser-Bestätigung
#   3. gh auth setup-git    →  git nutzt den OAuth-Token (https)
#   4. Zugriff aufs private Mesh-Repo prüfen → fertig
#
# Sicherheit:
#   - KEINE SSH-Keys werden erstellt, gelöscht oder angefasst
#   - Der User bestätigt explizit im Browser (OAuth-Scope: repo)
#   - Token liegt in gh's Credential-Store (nie im Klartext im Repo)

set -euo pipefail

AGENT_MESH_HOME="${AGENT_MESH_HOME:-$HOME/.agent-mesh}"
GH_ORG="${AGENT_MESH_GH_ORG:-moinsen-dev}"
GH_OWNER="${AGENT_MESH_GH_OWNER:-$GH_ORG}"
PRIVATE_REPO="agent-mesh-memories"

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "ℹ️  $*"; }
# macOS liefert bash 3.2 — ${var,,} ist bash-4-Syntax und bricht dort hart ab.
lower_of() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

cmd_connect() {
  info "🔐 Agent-Mesh Connect — Browser-Autorisierung mit GitHub"
  echo ""

  # ── 1. gh CLI prüfen ──
  if ! command -v gh >/dev/null 2>&1; then
    die "gh CLI fehlt — bitte installieren: https://cli.github.com (macOS: brew install gh)"
  fi

  # ── 2. Bereits eingeloggt? ──
  if gh auth status 2>/dev/null | grep "Logged in" >/dev/null; then
    local who
    who=$(gh api user --jq .login 2>/dev/null || echo "?")
    echo "──────────────────────────────────────────────"
    echo "  Bereits eingeloggt als: $who"
    echo "──────────────────────────────────────────────"
    echo ""
    read -r -p "👉 Darf ich diesen Account mit dem Agent-Mesh verknüpfen? (ja/nein) " answer
    case "$(lower_of "$answer")" in
      j|ja|y|yes|yo) ;;
      *) die "Abbruch — keine Verknüpfung. Jederzeit möglich: agent-mesh connect" ;;
    esac
  else
    # ── 3. Browser-Login starten (Device-Flow) ──
    echo "👉 Browser-Login wird gestartet. Du bekommst einen One-Time-Code:"
    echo ""
    gh auth login --hostname github.com --git-protocol https --web 2>&1
    echo ""
    info "✅ Login abgeschlossen (sofern du im Browser bestätigt hast)"
  fi

  # ── 4. git auf Token umstellen (https statt ssh) ──
  info "Konfiguriere git mit dem OAuth-Token…"
  gh auth setup-git 2>/dev/null || true

  # ── 5. Eigenes Mesh-Repo sicherstellen (JEDER User hat sein EIGENES!) ──
  local who
  who=$(gh api user --jq .login 2>/dev/null || echo "?")
  GH_OWNER="${AGENT_MESH_GH_OWNER:-$who}"
  info "Eigenes Mesh-Repo: $GH_OWNER/$PRIVATE_REPO …"
  if gh repo view "$GH_OWNER/$PRIVATE_REPO" >/dev/null 2>&1; then
    echo ""
    echo "✅ Verknüpfung bestätigt!"
    echo "   Account:  $who"
    echo "   Repo:     $GH_OWNER/$PRIVATE_REPO (Zugriff ✅)"
    echo ""
    echo "   Nächste Schritte:"
    echo "   agent-mesh init <name>    # Agent registrieren"
    echo "   agent-mesh sync           # Wissen exportieren + pushen"
    echo "   agent-mesh watch 60       # Auto-Sync (Cloudflare-frei!)"
  elif [ "$GH_OWNER" = "$who" ]; then
    # Repo existiert nicht, gehört aber dem User → automatisch anlegen!
    echo "   Repo existiert noch nicht — lege es an (privat)…"
    if gh repo create "$PRIVATE_REPO" --private --description "Agent-Mesh Memories (privat — nie public!)" >/dev/null 2>&1; then
      echo "✅ Eigenes Mesh-Repo angelegt: $GH_OWNER/$PRIVATE_REPO (privat)"
      echo ""
      echo "   Nächste Schritte:"
      echo "   agent-mesh init <name>    # Agent registrieren"
      echo "   agent-mesh sync           # Wissen exportieren + pushen"
      echo "   agent-mesh watch 60       # Auto-Sync (Cloudflare-frei!)"
      # In conf speichern, damit alle Module es kennen
      grep -q "^AGENT_MESH_GH_OWNER=" "$CONF" 2>/dev/null || echo "AGENT_MESH_GH_OWNER=$who" >> "$CONF" 2>/dev/null || true
      grep -q "^AGENT_MESH_PRIVATE_REPO=" "$CONF" 2>/dev/null || echo "AGENT_MESH_PRIVATE_REPO=$PRIVATE_REPO" >> "$CONF" 2>/dev/null || true
    else
      die "❌ Repo-Anlage fehlgeschlagen — bitte manuell: https://github.com/new (privat, Name: $PRIVATE_REPO)"
    fi
  else
    echo ""
    die "❌ Kein Zugriff auf $GH_OWNER/$PRIVATE_REPO (und du bist nicht der Owner)."
    echo "   Bitte den Repo-Owner bitten, '$who' als Collaborator einzuladen:"
    echo "   https://github.com/$GH_OWNER/$PRIVATE_REPO/settings/access"
  fi
}

# Als Befehl aufrufbar (wird aus agent-mesh gesourct — Dispatch dort)
