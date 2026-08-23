# Für Agenten, die in diesem Repo arbeiten

Hermes zieht diese Datei automatisch in den Kontext, sobald ein Agent im
Arbeitsverzeichnis dieses Klons läuft. Sie richtet sich an dich, nicht an
Menschen — die Menschen-Doku steht in README.md und docs/.

## Was dieses Repo ist

`agent-mesh` verbindet mehrere Hermes-Agenten zu einem Wissensverbund. Das
Repo ist zugleich **Framework** (die `agent-mesh*`-Skripte) und **Hermes-Profil-
Distribution** (`distribution.yaml`, `SOUL.md`, `skills/`, `cron/`, `scripts/`).

Willst du dich selbst in einen bestehenden Verbund einrichten, brauchst du
dieses Repo nicht zu lesen — eine Zeile genügt:

    hermes profile install github.com/moinsen-dev/agent-mesh --alias

Oder additiv, damit dein *bestehender* Agent mit seinem echten Gedächtnis
beitritt statt eines neuen, leeren:

    hermes skills install https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/skills/agent-mesh/SKILL.md

## Wenn du hier etwas änderst

- **`tests/run.sh` läuft vor jedem Commit.** Ohne Abhängigkeiten, in Sekunden.
- **`.github/scripts/check.sh` ebenso.** Jedes Muster darin stammt aus einem
  echten Fehler dieses Projekts; keines ist theoretisch.
- **Neues Kommando?** Es gehört in `agent-mesh-cli.sh` (Registry + Hilfe) *und*
  in den Dispatcher. Zwei Tests halten beide Seiten zusammen; sie scheitern,
  wenn du eine Seite vergisst.
- **Neues Modul?** Es muss in die Download-Liste von `install.sh`. Dreimal hat
  dort eine Datei gefehlt, und es fiel jedes Mal erst auf einer frisch
  installierten Maschine auf. Ein Test fängt das jetzt.
- **Version bumpen** heisst: `VERSION` *und* `AGENT_MESH_VERSION` in
  `agent-mesh-cli.sh` *und* `version:` in `distribution.yaml`. Ein Test hält
  die ersten beiden zusammen.
- **`docs/INSTALL.md` oder `docs/COMMANDS.md` angefasst?** Dann `python3
  generate.py` laufen lassen und README.md + site/index.html MITCOMMITTEN.
  Sonst schiebt die Action einen Commit nach — und ein Release-Tag, das du
  direkt davor gesetzt hast, zeigt danach auf einen Commit, der nicht mehr auf
  main liegt. Zweimal passiert; das Gate prüft es jetzt.
- **Release** ist ein signiertes Tag, kein GitHub-Release. Siehe
  `docs/RELEASING.md`. Ein unsigniertes Tag erreicht keine einzige Maschine.
  Reihenfolge: erst alles committen, dann taggen, dann `git push --follow-tags`.

## Die Haltung, an der hier alles hängt

Melde **Ergebnisse, keine Handlungen**. „Kopiert" ist keine Aussage darüber, ob
die Datei angekommen ist; „15 Dateien verifiziert in /usr/local/bin" ist eine.
Dieses Projekt hat dreimal Erfolg gemeldet, während nichts ankam — deshalb
prüft jeder schreibende Pfad hier sein eigenes Ergebnis nach.

Und: **erst nachsehen, ob Hermes es schon kann.** Der Verbund hat drei
Hermes-Subsysteme nachgebaut, bevor das jemandem auffiel (`hermes peer`,
`hermes sync`, `hermes memory`). `hermes <thema> --help` ist billiger als eine
zweite Implementierung.
