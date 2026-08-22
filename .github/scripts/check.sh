#!/usr/bin/env bash
# Syntax- und Muster-Gate für agent-mesh.
#
# Bewusst LAYOUT-AGNOSTISCH: Dateien werden über Shebang und Endung gefunden,
# nicht über feste Pfade. So überlebt dieses Gate eine Umstrukturierung des
# Quellbaums — und sichert sie ab, statt hinterherzuhinken.
#
# Die Muster unten stammen alle aus echten Funden des Sicherheits-Audits vom
# 2026-08-22. Jedes hat einmal wirklich wehgetan; keines ist theoretisch.
#
# Lokal ausführbar:  .github/scripts/check.sh

set -o pipefail   # bewusst kein -u: leere Arrays sind in bash 3.2 "unbound"
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

fail=0
note() { printf '  %s\n' "$*"; }
# grep liefert "datei:zeile:inhalt" — der Kommentar-Anker muss also hinter dem
# zweiten Doppelpunkt greifen, nicht am Zeilenanfang. (Erster Lauf dieses
# Gates hat sich prompt an den eigenen erklärenden Kommentaren verschluckt.)
no_comments() { grep -vE '^([^:]*:)?[0-9]+:[[:space:]]*#' || true; }
bad()  { fail=$((fail+1)); printf '  ❌ %s\n' "$*"; }

# ── Dateien finden (ohne .git, ohne Fremdcode) ──
# Kein mapfile: das ist bash 4, und dieses Skript soll auch auf macOS (3.2)
# laufen — genau die Falle, gegen die Prüfung 3 weiter unten schützt.
sh_files=(); py_files=(); js_files=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  # Dieses Skript selbst überspringen: es enthält notwendigerweise genau die
  # Muster, nach denen es sucht — in seinen eigenen Meldungstexten.
  case "$f" in */check.sh) continue ;; esac
  case "$f" in
    *.sh) sh_files+=("$f"); continue ;;
    *.py) py_files+=("$f"); continue ;;
    *.js) js_files+=("$f"); continue ;;
  esac
  # Ohne Endung: Shebang entscheidet
  case "$(head -c 80 "$f" 2>/dev/null | head -1)" in
    '#!'*bash*|'#!'*/sh) sh_files+=("$f") ;;
    '#!'*python*)        py_files+=("$f") ;;
    '#!'*node*)          js_files+=("$f") ;;
  esac
done < <(git ls-files 2>/dev/null || find . -type f -not -path './.git/*')

echo "── Syntax (${#sh_files[@]} Shell, ${#py_files[@]} Python, ${#js_files[@]} JS) ──"
for f in "${sh_files[@]}"; do bash -n "$f" 2>/dev/null || bad "bash -n: $f"; done
for f in "${py_files[@]}"; do
  python3 -c "import ast,io,sys; ast.parse(io.open(sys.argv[1],encoding='utf-8').read())" "$f" 2>/dev/null \
    || bad "python: $f"
done
if command -v node >/dev/null 2>&1; then
  for f in "${js_files[@]}"; do node --check "$f" >/dev/null 2>&1 || bad "node --check: $f"; done
else
  note "node fehlt — JS-Syntax übersprungen"
fi
[ "$fail" -eq 0 ] && note "✅ Syntax sauber"

echo ""
echo "── Muster aus dem Audit ──"

# 1) Fremddaten in einem `bash -c`-String (Befund 1: Issue-Titel → RCE)
#    Erlaubt bleibt `bash -c` mit einem Heredoc oder ohne Interpolation.
hits=$(grep -nE 'bash -c "[^"]*\$\{?[A-Za-z_]' "${sh_files[@]}" 2>/dev/null | no_comments)
if [ -n "$hits" ]; then
  bad "Variable in einem \`bash -c\`-String — Werte gehören über env an ein zitiertes Heredoc:"
  echo "$hits" | sed 's/^/       /'
else note "✅ kein \`bash -c\` mit Interpolation"; fi

# 2) execSync mit Template-String (Befund 7: Agent-Verzeichnisname → RCE)
hits=$(grep -nE 'execSync\(`[^`]*\$\{' "${js_files[@]}" 2>/dev/null | no_comments)
if [ -n "$hits" ]; then
  bad "execSync mit interpoliertem Template — execFileSync mit Argument-Array verwenden:"
  echo "$hits" | sed 's/^/       /'
else note "✅ kein execSync mit Interpolation"; fi

# 3) bash-4-Syntax (macOS liefert 3.2 — `vault revoke` lief dort NIE)
hits=$(grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)\}' "${sh_files[@]}" 2>/dev/null | no_comments)
if [ -n "$hits" ]; then
  bad "\${var,,} / \${var^^} ist bash 4 — macOS hat bash 3.2:"
  echo "$hits" | sed 's/^/       /'
else note "✅ keine bash-4-Substitution"; fi

# 4) Millisekunden-Timeouts in JS (zweimal hat ein zu kurzer Timeout ein
#    Problem VERDECKT statt gelöst — einmal die Injection aus Befund 7)
hits=$(grep -nE 'timeout: *([1-9][0-9]?)[^0-9]' "${js_files[@]}" 2>/dev/null | no_comments)
if [ -n "$hits" ]; then
  bad "timeout unter 100 — Node erwartet Millisekunden, das ist fast sicher gemeint als Sekunden:"
  echo "$hits" | sed 's/^/       /'
else note "✅ keine verdächtig kleinen JS-Timeouts"; fi

# 5) Vorhersagbare Pfade in world-writable /tmp (Befund 11: TOCTOU)
hits=$(grep -nE '(>|cp |mv |rm -rf |clone .*)"?/tmp/[A-Za-z0-9_.$-]+' "${sh_files[@]}" 2>/dev/null \
       | grep -v 'mktemp' | no_comments)
if [ -n "$hits" ]; then
  bad "Fester Pfad unter /tmp — mktemp verwenden oder direkt ans Ziel schreiben:"
  echo "$hits" | sed 's/^/       /'
else note "✅ keine vorhersagbaren /tmp-Pfade"; fi

# 6) `cmd | grep -q` in einem Skript mit pipefail (Fund vom 2026-08-22).
#    grep -q schliesst die Pipe beim ersten Treffer, der Schreiber bekommt
#    SIGPIPE, pipefail macht daraus einen Fehlschlag — die Bedingung wird also
#    genau dann falsch, WENN es einen Treffer gibt. Sichtbar erst, wenn die
#    Ausgabe den Pipe-Puffer (~64 KB) uebersteigt: in kleinen Tests gruen, in
#    der Praxis falsch. `ps ax` reichte dafuer aus.
hits=""
for f in "${sh_files[@]}"; do
  grep -q "set -.*pipefail" "$f" 2>/dev/null || continue
  h=$(grep -nE '\| *grep -q' "$f" 2>/dev/null | no_comments)
  [ -n "$h" ] && hits="$hits$f: $h"$'\n'
done
if [ -n "$hits" ]; then
  bad "\`| grep -q\` in einem pipefail-Skript — bei grosser Ausgabe kippt die Bedingung ins Gegenteil:"
  printf '%s' "$hits" | sed 's/^/       /'
  note "Abhilfe: -q weglassen und nach /dev/null umleiten, oder pgrep verwenden."
else note "✅ kein \`| grep -q\` unter pipefail"; fi

echo ""
echo "── Release-Hygiene ──"
if [ -f VERSION ] && [ -f MIGRATIONS.md ]; then
  v=$(cat VERSION)
  if grep -q "^## v$v\$" MIGRATIONS.md; then
    note "✅ MIGRATIONS.md hat einen Abschnitt für v$v"
  else
    bad "VERSION ist v$v, aber MIGRATIONS.md hat keinen '## v$v'-Abschnitt.
       Agents bekommen die Hinweise nur für Abschnitte in ihrem Versionsbereich —
       ein fehlender Abschnitt heißt: der Hinweis erscheint bei NIEMANDEM."
  fi
fi
if [ -s .github/allowed_signers ] \
   && [ "$(grep -cvE '^[[:space:]]*(#|$)' .github/allowed_signers)" -eq 0 ]; then
  bad "allowed_signers enthält keinen Schlüssel — Agents würden jedes Update verweigern"
else
  note "✅ Vertrauensbasis für Releases ist gesetzt"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "✅ Alle Prüfungen bestanden."
else
  echo "❌ $fail Prüfung(en) fehlgeschlagen."
fi
exit "$fail"
