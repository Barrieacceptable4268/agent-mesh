#!/usr/bin/env bash
# agent-mesh install.sh — Ein-Befehl-Installer für das Agent-Mesh.
#
# Installiert das Framework, initialisiert den lokalen Agent und macht
# den ersten Sync. Ein Agent (oder Mensch) braucht NUR:
#
#   curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/install.sh | bash
#
# Voraussetzungen: git, curl, ssh-Key auf GitHub, (age + sops für Vault,
# hermes für den Wissen-Export — optional, das Script prüft und meldet).
#
# Options:
#   AGENT_MESH_NAME=<name>   Agent-Name (sonst Hostname)
#   AGENT_MESH_HOME=<path>   Installationsort (Default $HOME/.agent-mesh)
#   AGENT_MESH_SKIP_INIT=1   Nur Framework installieren, kein init/sync

set -euo pipefail

REPO="moinsen-dev/agent-mesh"
BRANCH="main"
RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
GH="git@github.com:$REPO.git"
AGENT_MESH_HOME="${AGENT_MESH_HOME:-$HOME/.agent-mesh}"
BIN_DIR="${AGENT_MESH_BIN_DIR:-}"
# Bin-Verzeichnis wählen: /usr/local/bin wenn schreibbar, sonst ~/.local/bin
if [ -z "$BIN_DIR" ]; then
  if [ -w /usr/local/bin ] 2>/dev/null; then BIN_DIR=/usr/local/bin
  else BIN_DIR="$HOME/.local/bin"; fi
fi
mkdir -p "$BIN_DIR"
NAME="${AGENT_MESH_NAME:-$(hostname | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')}"

say() { printf '\033[1;34m[agent-mesh]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[agent-mesh]\033[0m ⚠ %s\n' "$*"; }
die()  { printf '\033[1;31m[agent-mesh]\033[0m ❌ %s\n' "$*" >&2; exit 1; }

# ── 1. Abhängigkeiten prüfen ──
need() { command -v "$1" >/dev/null 2>&1 || { warn "$1 fehlt — $2"; return 1; }; }
need git "https://git-scm.com" || true
need curl "in der Regel vorinstalliert" || true
need ssh "https://www.openssh.com" || true
command -v age >/dev/null 2>&1 || warn "age fehlt — Vault nur mit: apt install age (oder scoop install age auf Windows)"
command -v sops >/dev/null 2>&1 || warn "sops fehlt — Vault nur mit: https://github.com/getsops/sops/releases (scoop install sops auf Windows)"
command -v hermes >/dev/null 2>&1 || warn "hermes fehlt — Wissen-Export nur mit Hermes (https://hermes-agent.nousresearch.com)"

# ── 2. Framework-Dateien holen ──
say "Lade Framework vom public Repo ($REPO@$BRANCH)…"
for f in agent-mesh agent-mesh-a2a.sh agent-mesh-update.sh agent-mesh-webhook.py; do
  curl -fsSL "$RAW/$f" -o "$BIN_DIR/$f" 2>/dev/null \
    || die "Download fehlgeschlagen: $f (Netz? Repo-Name?)"
  chmod +x "$BIN_DIR/$f" 2>/dev/null || true
  say "  ✓ $f → $BIN_DIR/$f"
done

# ── 3. Alias/Link sicherstellen (falls BIN_DIR nicht im PATH) ──
if ! command -v agent-mesh >/dev/null 2>&1; then
  if [ "$BIN_DIR" = "$HOME/.local/bin" ]; then
    mkdir -p "$HOME/.local/bin"
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) ;;
      *) warn "~/.local/bin ist nicht im PATH — ergänze in ~/.bashrc:";
         echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
         echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
  fi
fi

# ── 4. GitHub-SSH-Zugang prüfen ──
say "Prüfe GitHub-SSH-Zugang…"
# WICHTIG: ssh gibt trotz erfolgreicher Auth manchmal exit 1 (TTY/redirect-Quirk)
# UND pipefail lässt die Pipe fehlschlagen → Ausgabe in Variable, dann grep
SSH_OUT=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com 2>&1 || true)
if ! echo "$SSH_OUT" | grep -q "successfully authenticated"; then
  warn "GitHub-SSH-Key fehlt — bitte einmal einrichten:"
  echo "    ssh-keygen -t ed25519"
  echo "    cat ~/.ssh/id_ed25519.pub   # auf https://github.com/settings/keys hinterlegen"
  if [ "${AGENT_MESH_SKIP_INIT:-0}" != "1" ]; then
    die "Abbruch: ohne GitHub-Zugang kann der Agent nicht ins Mesh."
  fi
fi

# ── 5. Initialisieren + Sync ──
if [ "${AGENT_MESH_SKIP_INIT:-0}" != "1" ]; then
  if [ ! -f "$AGENT_MESH_HOME/agent-mesh.conf" ]; then
    say "Initialisiere Agent '$NAME'…"
    AGENT_MESH_HOME="$AGENT_MESH_HOME" "$BIN_DIR/agent-mesh" init "$NAME"
  else
    say "Agent bereits initialisiert (Konfig vorhanden) — überspringe init."
    # Namen aus bestehender Conf lesen
    NAME=$(grep "^AGENT_NAME=" "$AGENT_MESH_HOME/agent-mesh.conf" | cut -d= -f2- || true)
  fi
  say "Erster Sync (Wissen exportieren + pushen)…"
  AGENT_MESH_HOME="$AGENT_MESH_HOME" "$BIN_DIR/agent-mesh" sync || warn "Sync meldete einen Fehler — Details oben."
  say "Status:"
  AGENT_MESH_HOME="$AGENT_MESH_HOME" "$BIN_DIR/agent-mesh" status || true
fi

say "✅ Fertig! Agent '$NAME' ist installiert."
say "   Nächste Schritte: agent-mesh role <hub|worker|specialist> · agent-mesh vault set <k> <v>"
