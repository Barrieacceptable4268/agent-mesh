#!/usr/bin/env bash
# Ein Abgleich des Verbunds — von `hermes cron` alle 10 Minuten aufgerufen.
#
# Gehört nach ~/.hermes/scripts/mesh-converge.sh. Läuft mit --no-agent, also
# ohne Sprachmodell: Konvergenz ist eine mechanische Angelegenheit und braucht
# kein Denken. Leere Ausgabe = nichts passiert = keine Meldung.
#
# Damit ersetzt ein Hermes-Cron-Job den eigenen watch-Dämon des Werkzeugs.
# Der Unterschied ist nicht kosmetisch: `hermes gateway install` richtet den
# Dienst auf macOS, Linux und Windows ein und startet ihn nach Absturz und
# Neustart wieder — ein zweiter, selbstgebauter Dienst pro Betriebssystem war
# genau die Doppelarbeit, an der am 22.08.2026 zwei Agenten hängengeblieben
# sind.
set -uo pipefail
command -v agent-mesh >/dev/null 2>&1 || {
  echo "agent-mesh ist auf dieser Maschine nicht installiert."
  exit 0
}
exec agent-mesh converge --quiet
