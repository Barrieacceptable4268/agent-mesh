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

# ── Signatur-Prüfung für Releases (Audit-Befund 8) ──
# Bis v1.13 installierte jeder Agent stündlich als root, was gerade im
# Public-Repo stand — ungeprüft. Wer dort pushen konnte, besass damit binnen
# einer Stunde jede Maschine im Mesh. Aus einer einzelnen Kompromittierung
# wurde so eine Mesh-weite.
#
# Ab v1.14.0 wird nur noch installiert, was als Git-Tag mit einem
# VERTRAUTEN SSH-Key signiert ist — und der Inhalt kommt aus dem TAG, nicht
# aus main (sonst genügte ein altes signiertes Tag plus manipuliertes main).
#
# Die Vertrauensbasis liegt LOKAL beim Agent, nicht im Repo: wer das Repo
# manipulieren kann, darf nicht zugleich festlegen, wem der Agent vertraut.
SIGNERS_FILE="${AGENT_MESH_SIGNERS_FILE:-$AGENT_MESH_HOME/trusted_signers}"

# Signatur eines Release-Tags prüfen. 0 = vertrauenswürdig.
verify_release_tag() {
  # $1 = Tag-Name (z.B. v1.14.0)
  local tag="$1"
  if [ ! -s "$SIGNERS_FILE" ]; then
    echo "  ❌ Keine vertrauten Signaturschlüssel hinterlegt ($SIGNERS_FILE)" >&2
    echo "     → einmalig einrichten: agent-mesh trust" >&2
    return 1
  fi
  ( cd "$FRAMEWORK_DIR" && git fetch --quiet origin "refs/tags/$tag:refs/tags/$tag" --force 2>/dev/null ) || true
  local out rc
  out=$(cd "$FRAMEWORK_DIR" && git -c gpg.format=ssh \
          -c gpg.ssh.allowedSignersFile="$SIGNERS_FILE" \
          verify-tag "$tag" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  ❌ Signatur von '$tag' NICHT vertrauenswürdig — Update abgebrochen." >&2
    echo "$out" | sed 's/^/     /' >&2
    echo "     Mögliche Gründe: Tag unsigniert, mit fremdem Key signiert," >&2
    echo "     oder dein trusted_signers ist veraltet (agent-mesh trust --show)." >&2
    return 1
  fi
  echo "  🔏 $tag: $(echo "$out" | head -1)"
  return 0
}

# Versionsvergleich: 0 wenn $1 < $2 (echter Fortschritt)
version_lt() {
  [ "$1" = "$2" ] && return 1
  local lo
  lo=$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
  [ "$lo" = "$1" ]
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

  # ── Rekursive Suche statt Wurzel-Globs (Vorbereitung auf v2) ──
  # Bisher wurden nur Dateien DIREKT im Repo-Wurzelverzeichnis gefunden. Zieht
  # der Quellbaum nach bin/ lib/ web/ um, findet eine alte Kopierschleife dort
  # nichts mehr — und weil beim Update immer noch die ALTE Schleife läuft,
  # bliebe die Flotte auf dem Stand davor stehen. Genau diese Falle hatten wir
  # schon bei .js. Deshalb muss diese Version EINE RELEASE FRÜHER ausgerollt
  # sein als der Umzug selbst.
  #
  # Das INSTALLIERTE Layout bleibt bewusst flach: das Hauptskript sucht seine
  # Module über dirname "$0" gleich neben sich. Nur das Repo wird strukturiert.
  local copied=0 collisions=0
  local seen_list=""
  local f base tmp

  while IFS= read -r f; do
    [ -f "$f" ] || continue
    base=$(basename "$f")

    # Doppelte Basisnamen aus verschiedenen Verzeichnissen wären ein stiller
    # Überschreib-Unfall — lieber laut melden und den zweiten auslassen.
    case " $seen_list " in
      *" $base "*)
        echo "  ⚠️  '$base' kommt mehrfach vor — '$f' übersprungen"
        collisions=$((collisions+1))
        continue ;;
    esac
    seen_list="$seen_list $base"

    # ATOMARER Tausch (hermes-hetzner-Fund, v1.10.1): erst Temp-Datei, dann mv
    # — sonst überschreibt sich ein laufendes Bash-Skript selbst.
    tmp="$dst/.$base.tmp.$$"
    if cp "$f" "$tmp" && chmod +x "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$dst/$base" 2>/dev/null \
        || { rm -f "$tmp"; cp "$f" "$dst/$base"; chmod +x "$dst/$base" 2>/dev/null; }
      echo "  ✓ $base → $dst/$base"
      copied=$((copied+1))
    fi
  done << FIND_EOF
$(find "$src" \
    \( -name .git -o -name docs -o -name site -o -name .github \
       -o -name node_modules -o -name tests \) -prune -o \
    -type f \( -name 'agent-mesh' -o -name 'agent-mesh-*.sh' \
                -o -name 'agent-mesh-*.py' -o -name 'agent-mesh-*.js' \
                -o -name 'mesh' -o -name 'mesh-*.sh' \
                -o -name 'mesh-*.py' -o -name 'mesh-*.js' \) -print 2>/dev/null | sort)
FIND_EOF

  if [ "$copied" -eq 0 ]; then
    echo "  ⚠️  Keine Framework-Dateien gefunden in $src — Update unvollständig!"
  fi
  [ "$collisions" -gt 0 ] && echo "  ⚠️  $collisions Namenskollision(en) — bitte im Repo bereinigen"
  # Verlinken, falls $HOME/.local/bin nicht im PATH (Linux)
  if [ "$dst" = "$HOME/.local/bin" ] && ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    echo "⚠  Füge ~/.local/bin zum PATH hinzu (oder nutze: $dst/agent-mesh)"
  fi
}

# ── Migrations-Hinweise anzeigen (ab v1.11.0) ──
# Ein Update, das stillschweigend das Protokoll ändert, ist eine Falle: Der
# Agent läuft weiter, aber irgendetwas tut es nicht mehr, und niemand weiß
# warum. Deshalb bekommt JEDER Agent nach dem Update genau die Abschnitte aus
# MIGRATIONS.md zu sehen, die zwischen seiner alten und der neuen Version
# liegen — im Terminal wie im watch.log.
show_migrations() {
  # $1 = Version VORHER, $2 = Version NACHHER
  local mf="$FRAMEWORK_DIR/MIGRATIONS.md"
  [ -f "$mf" ] || return 0
  local notes
  notes=$("$PYTHON_BIN" - "$mf" "$1" "$2" << 'MIGPY'
import re, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]

def ver(v):
    nums = re.findall(r"[0-9]+", v)[:3]
    return tuple(int(x) for x in nums) if nums else (0, 0, 0)

text = open(path, encoding="utf-8").read()
out = []
for part in re.split(r"^## v", text, flags=re.M)[1:]:
    head = part.split("\n", 1)[0].strip()
    if ver(old) < ver(head) <= ver(new):
        out.append("## v" + part.rstrip())
print("\n\n".join(out))
MIGPY
)
  [ -n "$notes" ] || return 0
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  ⚠️  MIGRATION: v$1 → v$2 — bitte einmal lesen"
  echo "════════════════════════════════════════════════════════════════"
  echo "$notes"
  echo "════════════════════════════════════════════════════════════════"
  echo "  Prüfen, ob alles sitzt:  agent-mesh doctor --security"
  echo "  Nochmal nachlesen:       $mf"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
}

# ── agent-mesh trust — Vertrauensbasis für Release-Signaturen ──
# Gleiches Muster wie beim Key-Pinning (Befund 6): beim ersten Mal übernehmen
# und laut sagen, danach jede Änderung als Ereignis behandeln statt still zu
# akzeptieren. Die Datei im Repo ist nur ein VORSCHLAG — massgeblich ist die
# lokale Kopie, sonst bestimmt der, der das Repo manipuliert, auch das
# Vertrauen.
cmd_trust() {
  load_conf
  local repo_file="$FRAMEWORK_DIR/.github/allowed_signers"
  local sub="${1:-}"

  case "$sub" in
    --show|show)
      if [ -s "$SIGNERS_FILE" ]; then
        echo "Vertraute Release-Signaturschlüssel ($SIGNERS_FILE):"
        sed 's/^/  /' "$SIGNERS_FILE"
      else
        echo "Keine vertrauten Schlüssel hinterlegt ($SIGNERS_FILE)."
        echo "→ einrichten: agent-mesh trust"
      fi
      return 0 ;;
  esac

  # Der lokale Klon kann aelter sein als die Einfuehrung der Signaturen — dann
  # steht die Datei dort noch nicht. Ohne Ausweg haengt der Agent fest: trust
  # braucht die Datei, und update rueckt den Klon ohne Vertrauensbasis nicht
  # vor. Deshalb notfalls direkt von origin/main holen. Das ist unbedenklich:
  # die Datei ist ohnehin nur ein VORSCHLAG, den der Mensch gleich bestaetigt.
  if [ ! -f "$repo_file" ]; then
    local fetched; fetched=$(mktemp)
    if (cd "$FRAMEWORK_DIR" && git fetch --quiet origin main 2>/dev/null \
        && git show origin/main:.github/allowed_signers 2>/dev/null) > "$fetched" \
        && [ -s "$fetched" ]; then
      repo_file="$fetched"
      echo "ℹ️  Signaturschluessel von origin/main geholt (lokaler Klon ist aelter)."
    else
      rm -f "$fetched"
      die "Signaturschluessel nicht auffindbar — weder lokal noch auf origin/main.
  → Netzverbindung pruefen, sonst den Framework-Klon erneuern:
    rm -rf \"$FRAMEWORK_DIR\" && agent-mesh update"
    fi
  fi

  # Eine Datei aus lauter Kommentaren ist KEINE Vertrauensbasis. Sonst pinnt
  # der Agent etwas Leeres, und jede spätere Signaturprüfung scheitert mit
  # einer Meldung, die das eigentliche Problem verdeckt.
  if [ "$(grep -cvE '^[[:space:]]*(#|$)' "$repo_file")" -eq 0 ]; then
    die "In .github/allowed_signers steht noch kein Schlüssel — das Projekt hat
  die Release-Signierung noch nicht eingerichtet.
  → Anleitung: $FRAMEWORK_DIR/docs/RELEASING.md"
  fi

  if [ ! -s "$SIGNERS_FILE" ]; then
    mkdir -p "$(dirname "$SIGNERS_FILE")"
    cp "$repo_file" "$SIGNERS_FILE"
    chmod 600 "$SIGNERS_FILE"
    echo "🔏 Release-Signaturschlüssel erstmalig übernommen:"
    sed 's/^/  /' "$SIGNERS_FILE"
    echo ""
    echo "Ab jetzt installiert dieser Agent nur noch Releases, die mit einem"
    echo "dieser Schlüssel signiert sind. Prüfe die Fingerabdrücke bei"
    echo "Gelegenheit über einen zweiten Kanal gegen den Maintainer."
    return 0
  fi

  if cmp -s "$repo_file" "$SIGNERS_FILE"; then
    echo "✅ Vertrauensbasis unverändert — nichts zu tun."
    return 0
  fi

  echo "⚠️  Die Signaturschlüssel im Repo weichen von deinen lokalen ab:"
  echo ""
  diff -u "$SIGNERS_FILE" "$repo_file" 2>/dev/null | sed 's/^/  /' | tail -20
  echo ""
  echo "Das ist entweder ein legitimer Schlüsselwechsel — oder jemand versucht,"
  echo "sich selbst zu einem vertrauenswürdigen Herausgeber zu machen."
  echo "→ NICHT bestätigen, ohne die neuen Fingerabdrücke über einen ZWEITEN"
  echo "  Kanal (Anruf, Signal) mit dem Maintainer abgeglichen zu haben."
  read -r -p "👉 Neue Schlüssel übernehmen? (uebernehmen) " answer
  [ "$(lower_of "$answer")" = "uebernehmen" ] || die "Abgebrochen — Vertrauensbasis unverändert."
  cp "$repo_file" "$SIGNERS_FILE"
  chmod 600 "$SIGNERS_FILE"
  echo "✅ Vertrauensbasis aktualisiert."
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
    local before; before=$(local_version)

    # Repo fehlt → klonen (ohne Klon kann nichts geprüft werden)
    if [ ! -d "$FRAMEWORK_DIR/.git" ]; then
      GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-}" git clone "git@github.com:$GH_ORG/$PUBLIC_REPO.git" "$FRAMEWORK_DIR" 2>&1 | tail -1
    fi

    # Downgrade-Schutz: ein manipuliertes main könnte VERSION auf ein altes,
    # gültig signiertes Release zurückdrehen und so eine geflickte Lücke
    # wieder aufreissen.
    if [ "${1:-}" != "--force" ] && version_lt "$remote" "$before"; then
      echo "❌ Remote-Version v$remote ist ÄLTER als die lokale v$before — abgebrochen."
      echo "   Das ist entweder ein Versehen oder ein Downgrade-Versuch."
      echo "   Bewusst zurück: agent-mesh update --force"
      return 1
    fi

    echo "── Release-Signatur prüfen ──"
    if ! verify_release_tag "v$remote"; then
      echo "❌ Update NICHT durchgeführt. Der Agent bleibt auf v$before."
      return 1
    fi

    echo "── Auf das signierte Tag setzen ──"
    # Bewusst aus dem TAG, nicht aus main: nur der Tag ist signiert.
    (cd "$FRAMEWORK_DIR" && git reset --hard "v$remote" 2>&1 | tail -1)

    echo "── Installieren ──"
    install_framework
    echo "✅ Update abgeschlossen — neue Version: v$(local_version)"
    show_migrations "$before" "$(local_version)"
    # Nach Update: Webhook-Dienst neu laden (falls vorhanden)
    if systemctl is-active mesh-webhook >/dev/null 2>&1; then
      systemctl restart mesh-webhook 2>/dev/null && echo "  ✓ mesh-webhook neu gestartet"
    fi
  fi

  # Optional Hermes-Hinweis
  update_hermes
}
