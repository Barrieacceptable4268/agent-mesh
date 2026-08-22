#!/usr/bin/env bash
# agent-mesh-update — Update-Mechanismus für das Agent-Mesh Framework.
#
# Läuft als Teil von `mesh update` (eingebunden aus dem Hauptskript):
#   1. Prüft die aktuelle Version gegen das public Repo (agent-mesh)
#   2. Pullt neue Framework-Dateien (mesh, mesh-a2a.sh, mesh-webhook.py)
#   3. Installiert sie nach /usr/local/bin (bzw. dem Installationsort)
#   4. Optional: hermes update (Agent selbst aktuell halten)
#
# Versionierung: VERSION-Datei im Repo-Root, einfach monoton hochzählen.

VERSION_FILE="VERSION"

# Aktuelle lokale Version lesen (Default 0.1.0)
local_version() {
  if [ -f "$FRAMEWORK_DIR/$VERSION_FILE" ]; then
    cat "$FRAMEWORK_DIR/$VERSION_FILE"
  else
    echo "0.1.0"
  fi
}

# Neueste Version vom Remote — via git fetch (raw.githubusercontent cached unzuverlässig!)
remote_version() {
  if [ -d "$FRAMEWORK_DIR/.git" ]; then
    (cd "$FRAMEWORK_DIR" && git fetch origin main --quiet 2>/dev/null; \
     git show origin/main:VERSION 2>/dev/null) || echo "0.1.0"
  else
    echo "0.1.0"
  fi
}

# Framework-Dateien installieren (mesh + Module)
install_framework() {
  local src="$FRAMEWORK_DIR"
  local dst="/usr/local/bin"
  # Windows/git-bash: ~/.local/bin als Fallback, wenn /usr/local/bin nicht schreibbar
  if [ ! -w "$dst" ]; then
    dst="$HOME/.local/bin"
    mkdir -p "$dst"
  fi
  # ZUKUNFTSSICHER: Wildcard-basiert statt fester Dateiliste!
  # Matcht agent-mesh, agent-mesh-*.sh, agent-mesh-*.py (und Legacy mesh* für
  # Alt-Installationen). Verhindert den Chicken-Egg-Bug: alte Update-Module
  # mit alten Namen kopieren nichts, neue Dateien werden automatisch mitgenommen.
  local copied=0
  for f in "$src"/agent-mesh "$src"/agent-mesh-*.sh "$src"/agent-mesh-*.py \
           "$src"/mesh "$src"/mesh-*.sh "$src"/mesh-*.py; do
    [ -f "$f" ] || continue
    local base; base=$(basename "$f")
    cp "$f" "$dst/$base" && chmod +x "$dst/$base" 2>/dev/null
    echo "  ✓ $base → $dst/$base"
    copied=$((copied+1))
  done
  if [ "$copied" -eq 0 ]; then
    echo "  ⚠️  Keine Framework-Dateien gefunden in $src — Update unvollständig!"
  fi
  # Verlinken, falls $HOME/.local/bin nicht im PATH (Linux)
  if [ "$dst" = "$HOME/.local/bin" ] && ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    echo "⚠  Füge ~/.local/bin zum PATH hinzu (oder nutze: $dst/agent-mesh)"
  fi
}

# Optional: Hermes selbst aktualisieren
update_hermes() {
  if command -v hermes >/dev/null 2>&1; then
    echo "── Hermes-Update-Check ──"
    hermes update --check 2>&1 | head -3
    echo "  (hermes update --yes führt es aus; Vorsicht: startet Gateway neu!)"
  fi
}

cmd_update() {
  load_conf
  local do_check=""
  [ "${1:-}" = "--check" ] && do_check=1
  [ "${1:-}" = "--hermes" ] && { do_check=1; }

  echo "── Agent-Mesh Update ──"
  echo "  Lokal:   v$(local_version)"
  local remote; remote=$(remote_version)
  echo "  Remote:  v$remote"

  if [ "$(local_version)" = "$remote" ]; then
    echo "✅ Framework ist aktuell (v$remote)"
  else
    echo "⬆️  Update verfügbar (v$(local_version) → v$remote)"
  fi

  [ -n "$do_check" ] && { update_hermes; return 0; }

  if [ "$(local_version)" != "$remote" ] || [ "${1:-}" = "--force" ]; then
    echo "── Pull vom public Repo ──"
    if [ -d "$FRAMEWORK_DIR/.git" ]; then
      # Framework-Klon ist nur ein Cache — lokale Änderungen (z.B. Test-VERSION)
      # sind safe zu verwerfen/stashen. Erst versuchen sauber zu pullen, sonst hard-reset.
      (cd "$FRAMEWORK_DIR" && git pull --rebase origin main 2>&1 | tail -1) \
        || (cd "$FRAMEWORK_DIR" && git stash 2>/dev/null; git reset --hard origin/main 2>&1 | tail -1)
    else
      # Repo fehlt → klonen
      GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-}" git clone "git@github.com:$GH_ORG/$PUBLIC_REPO.git" "$FRAMEWORK_DIR" 2>&1 | tail -1
    fi
    echo "── Installieren ──"
    install_framework
    echo "✅ Update abgeschlossen — neue Version: v$(local_version)"
    # Nach Update: Webhook-Dienst neu laden (falls vorhanden)
    if systemctl is-active mesh-webhook >/dev/null 2>&1; then
      systemctl restart mesh-webhook 2>/dev/null && echo "  ✓ mesh-webhook neu gestartet"
    fi
  fi

  # Optional Hermes-Hinweis
  update_hermes
}
