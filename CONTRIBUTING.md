# Mitwirken an agent-mesh

Danke, dass du hier bist. Kurz und ehrlich vorweg:

## Wir nehmen derzeit keine Pull Requests an

agent-mesh ist noch jung und bewegt sich schnell. Das Framework installiert
sich per `curl | bash`, läuft als Dienst auf fremden Rechnern, hält private
Schlüssel und aktualisiert sich stündlich selbst. Änderungen daran wandern
also innerhalb einer Stunde auf jede Maschine im Mesh — auch auf deine.

Bei diesem Zuschnitt können wir fremden Code im Moment nicht in der Tiefe
prüfen, die er verdient. Einen PR halb zu reviewen wäre schlechter, als ihn
gar nicht anzunehmen. Deshalb: **bitte keine Pull Requests.**

## Was wir uns wünschen: Issues

Ein gutes Issue ist uns mehr wert als ein PR — es sagt uns, wo es klemmt, und
lässt uns die Lösung in den Gesamtzusammenhang stellen.

**Fehler melden** → https://github.com/moinsen-dev/agent-mesh/issues/new

Hilfreich ist:
- Betriebssystem und Shell (`uname -a`, `bash --version`)
- Was du getan hast, was passiert ist, was du erwartet hast
- Die Ausgabe von `agent-mesh doctor` — sie deckt die meisten Ursachen auf
- Bei Update-Problemen: `agent-mesh update --check`

**Feature-Idee** → ebenfalls als Issue, gern mit dem Anwendungsfall dahinter.
Das *Warum* ist wichtiger als das *Wie*: Wir bauen es vielleicht anders, als
du es vorschlägst, aber nur, wenn wir verstehen, worum es dir geht.

**Frage** → auch ein Issue. Wenn du etwas nicht findest, fehlt meistens die
Dokumentation, nicht das Wissen.

## Sicherheitslücken

**Bitte nicht als öffentliches Issue.** Schreib an
[developer@moinsen.dev](mailto:developer@moinsen.dev) oder nutze GitHub
Security Advisories:
https://github.com/moinsen-dev/agent-mesh/security/advisories/new

Wegen der Selbst-Update-Funktion trifft eine Lücke hier sofort jeden
laufenden Agent. Wir reagieren entsprechend zügig und nennen dich auf Wunsch
in den Release-Notes.

## Wenn du das Ding für dich umbauen willst

Nur zu — dafür ist es offen. Der saubere Weg ist ein **eigenes Mesh** statt
eines PRs:

```bash
export AGENT_MESH_GH_ORG="dein-github-name"
agent-mesh connect          # legt dein eigenes privates Mesh-Repo an
```

Dein Fork, deine Regeln, deine Daten. Wenn dabei etwas entsteht, das andere
gebrauchen können: erzähl uns in einem Issue davon.

## Wird sich das ändern?

Ja. Sobald das Framework ruhiger läuft, es Tests gibt, die eine fremde
Änderung tragen können, und die Sicherheits-Grundlagen sitzen, öffnen wir für
PRs. Dann steht es hier — und wer bis dahin ein Issue beigetragen hat, ist die
erste Adresse, die wir fragen.

Bis dahin: Issues sind willkommen, und sie werden gelesen.
