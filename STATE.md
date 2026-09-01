# STATE — agent-mesh

> **Frozen:** 2026-08-24 17:55
> **Branch:** main
> **Last commit:** 8cb1b35 · fix: ein Gedankenstrich hat die Telemetrie der ganzen Flotte eingefroren
> **Dirty:** clean (STATE.md selbst ist der einzige neue Stand)
> **Version:** 1.37.1 · 86 Tests grün · check.sh grün

## Last work-unit

Der Tag hat das Projekt von „lose Skriptsammlung" auf eine CLI mit Testsuite
gebracht (v1.28 → v1.37.1, 15 Releases). Die zwei tragenden Entscheidungen:
**Hermes macht das Denken, das Einrichten und das Gedächtnis** — agent-mesh
behält Vault, Signaturkette, Flottensicht und Onboarding; und **Konvergenz
statt Signal** — jeder Agent stellt seinen Soll-Zustand selbst her.

Zuletzt (v1.37.0) hat der Verbund gelernt, sich selbst in Ordnung zu bringen,
statt dass ein Mensch denselben Befehl auf sechs Rechnern tippt. Beim Parken
fiel auf, dass alle fünf Agenten seit vier Stunden schwiegen: `cut -c1-58`
zählt ohne gesetztes Locale **Bytes**, der Gedankenstrich einer Commit-Meldung
lag auf Byte 56, der Bericht wurde ungültiges UTF-8 — und weil alle Agenten
denselben Framework-Commit melden, hörten alle gleichzeitig auf. Behoben in
v1.37.1; dev-docker hat sich daraufhin binnen Sekunden selbst geheilt.

## Next intended step

**Zusehen, ob die Flotte von allein zusammenkommt — ohne einen Befehl auf einer
Maschine.** Erfolgskriterium: `agent-mesh fleet` zeigt alle fünf aktiven Agenten
auf 1.37.1, `LETZTES LZ` unter 1h, und unter „Laufende Komponenten" steht
`watch-alt` bei niemandem mehr.

Passiert das nicht binnen ~2h, ist der Grund vermutlich, dass die alte
watch-Schleife auf ax41/hermes-hetzner das Framework nur stündlich prüft. Die
einzige legitime Abkürzung ist **`agent-mesh maintenance` auf ax41** — nur der
Hub darf das Signal geben, dieser Rechner ist worker.

Danach, in dieser Reihenfolge:
1. **mem0-Server auf dem Hetzner** hochziehen (`deploy/memory-server.md`), dann
   einmal `agent-mesh memory setup --host … --key …`, dann überall `join`.
   Das ist das Stück, das aus sechs Dateiteilern ein denkendes Kollektiv macht.
2. **Aufräumen** auf Basis der Komponenten-Tabelle — NICHT auf Verdacht.
3. **Go-Frage** neu stellen, wenn der Kern geschrumpft ist (~2.500 Zeilen).

## Open friction

- **nucbox-evo-x2 ist pausiert** (`agent-mesh pause`), wartet auf eine NVMe-SSD.
  Kommt sie zurück, meldet die Übersicht „pausiert, meldet sich aber" →
  `agent-mesh resume nucbox-evo-x2`.
- **relay, webhook und dashboard laufen auf ax41** (webhook auch auf dev-docker).
  Meine Schätzung „2.041 Zeilen tot" war falsch — nicht löschen.
- **ax41, hermes-hetzner hängen noch am alten Dauerprozess** (`watch-alt`).
  Sollte die Selbstinstandsetzung erledigen, sobald 1.37.x dort liegt.
- **macmini** meldet „seit 15 Min keine Konvergenz" bei frischem Bericht — der
  laufende Prozess führt noch alten Code aus. Löst sich mit dem Dienstwechsel.
- **`autofix` erfindet weiter**: schreibt Code-Fixes per kontextlosem DeepSeek,
  dieselbe Klasse wie der alte Responder. Ungefixt.
- Kein SSH und kein Tailscale von diesem Rechner zu ax41/macmini/nucbox.

## Live context for the agent

- **Heisse Dateien:** `agent-mesh-doctor.sh` (report/fleet/pause/Komponenten),
  `agent-mesh-watch.sh` (converge/Bremse), `agent-mesh-a2a.sh` (self_repair),
  `tests/run.sh` (86 Tests).
- **Arbeitsweise, die sich bewährt hat:** jeden Test durch **Mutation** prüfen —
  in dieser Sitzung waren vier Tests vakuum-wahr, bevor die Mutation es zeigte.
- **Vor dem Release:** `python3 generate.py` laufen lassen, wenn `docs/INSTALL.md`
  oder `docs/COMMANDS.md` berührt wurden, sonst entwertet der Bot-Commit das Tag.
  Version steht an drei Stellen: `VERSION`, `agent-mesh-cli.sh`, `distribution.yaml`.
- **User-Haltung:** will, dass der Verbund sich selbst regelt — „ein Befehl pro
  Maschine" ist die falsche Antwort und war es fünf Releases lang.
- **Kalibrierung:** 15 Releases inklusive Analyse, Tests und Rollout an einem
  Arbeitstag. Zweimal war die naheliegende Ursache die falsche (`gh api user`,
  „2.041 Zeilen tot") — messen war jedes Mal billiger als reparieren.

## How to resume

1. Diese Datei lesen, dann `git log -5 --oneline` und `git status -s`.
2. `agent-mesh fleet` — das ist der eigentliche Zustand, nicht das Repo.
3. Abweichungen zuerst benennen, dann in 3-4 Sätzen zusammenfassen und auf
   Bestätigung warten.
