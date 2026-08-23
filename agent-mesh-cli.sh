#!/usr/bin/env bash
# agent-mesh-cli — das Gerüst der Kommandozeile: Registry, Hilfe, Version.
#
# Bis v1.27.0 war die einzige Selbstauskunft dieses Werkzeugs eine Zeile:
#
#   Usage: agent-mesh {init|sync|send|reply|…}
#
# 24 Kommandos, kein --help, kein --version, keine Erklärung, was ein Flag tut.
# `agent-mesh --version` landete im Fehlerfall-Zweig. Wer wissen wollte, dass
# `doctor` ein `--fix` kennt, musste den Quelltext lesen — auf einer Maschine,
# auf der das Framework installiert, aber der Quelltext gar nicht vorhanden ist.
#
# Dieses Modul ist die eine Stelle, an der jedes Kommando sich selbst erklärt.
# Es hat bewusst KEINE Abhängigkeit zu load_conf: Hilfe und Version müssen auch
# auf einem nicht eingerichteten Rechner funktionieren — dort braucht man sie
# am dringendsten.
#
# bash 3.2 (macOS) ist die Untergrenze: keine assoziativen Arrays, kein
# ${var,,}, kein mapfile.

# ── Die Version des LAUFENDEN Codes ───────────────────────────────────────
# Bewusst hier eingebettet und nicht aus $FRAMEWORK_DIR/VERSION gelesen: die
# Datei im Klon sagt, welche Version geholt wurde, nicht welche installiert
# ist. Genau diese Verwechslung hat die Flotte schon zweimal grün aussehen
# lassen, während der alte Stand lief. Der CI-Check hält beide Werte gleich.
AGENT_MESH_VERSION="1.28.0"

# ── Die Registry ───────────────────────────────────────────────────────────
# Ein Datensatz pro Kommando:  gruppe|name|argumente|kurztext
# Reihenfolge = Anzeigereihenfolge. "intern" wird in der Übersicht ausgelassen,
# hat aber trotzdem eine Hilfe — es sind die Kommandos, die Dienste aufrufen.
cli_registry() {
  cat << 'REG'
VERBUND|init|<agent-name>|Erste Einrichtung: Schlüsselpaar, Konfiguration, Registrierung
VERBUND|connect||GitHub-Konto verknüpfen (OAuth-Device-Flow, keine SSH-Keys)
VERBUND|sync||Pull → Wissen exportieren/importieren → Push
VERBUND|status||Wer ist im Verbund? Vault-Zustand?
VERBUND|agents||Alle Agent-Karten mit ihren Rollen
NACHRICHT|send|<agent> <text>|Nachricht an einen Agent (Git-Warteschlange, keine offenen Ports)
NACHRICHT|broadcast|<text>|Dieselbe Nachricht an alle Agents
NACHRICHT|inbox||Eigene Mailbox lesen
NACHRICHT|reply|<msg-id> <text>|Antworten — das Original wird selbst gefunden
NACHRICHT|route|<agent> <text>|Nur Hub: eine Nachricht weiterleiten
NACHRICHT|role|<rolle>|Eigene Rolle setzen: hub, worker oder specialist
NACHRICHT|respond||Eingegangene Nachrichten automatisch beantworten
VAULT|vault|<unterkommando>|Verschlüsselte Secrets — set, get, list, add-key, revoke, pins, repin
VAULT|insight|add <text>|Eine Erkenntnis mit allen teilen (Markdown)
BETRIEB|converge||EIN idempotenter Abgleich: Soll-Zustand herstellen und melden
BETRIEB|watch|[sekunden]|Dauerlauf: converge alle N Sekunden (Default 60)
BETRIEB|service|<unterkommando>|watch als Systemdienst — install, status, restart, logs, uninstall
BETRIEB|update|[--check]|Framework aktualisieren (nur signierte Releases)
BETRIEB|trust|[--show]|Vertrauensbasis für Release-Signaturen einsehen/übernehmen
FLOTTE|doctor|[--fix]|Installation, Schlüssel, Dienste prüfen
FLOTTE|report|[--json]|Kompakter, nachprüfbarer Zustandsbericht dieser Maschine
FLOTTE|fleet||Hub-Sicht: der Zustand jedes Agents aus seinem eigenen Bericht
FLOTTE|maintenance|[--dry-run]|Allen Agents sagen, dass sie sich aktualisieren sollen
WERKSTATT|govern|<unterkommando>|Selbstverwaltung: Issues an Agents verteilen
WERKSTATT|autofix|<unterkommando>|Selbstverbesserung: Issue beheben und PR öffnen
intern|peer-recv||Relay-Warteschlange leeren (vom watch-Dienst aufgerufen)
intern|maintenance-run||Eingegangene Wartungssignale ausführen (vom watch-Dienst aufgerufen)
REG
}

cli_known_commands() { cli_registry | cut -d'|' -f2; }

cli_is_command() {
  local c
  for c in $(cli_known_commands); do [ "$c" = "$1" ] && return 0; done
  return 1
}

# ── Version ────────────────────────────────────────────────────────────────
# Sagt drei Dinge, weil zwei davon schon einmal auseinandergelaufen sind:
# was läuft, was im Klon liegt, und von wo es aufgerufen wird.
cli_version() {
  local self clone
  self=$(command -v agent-mesh 2>/dev/null || echo "$0")
  echo "agent-mesh $AGENT_MESH_VERSION"
  echo "  läuft aus   $self"
  clone=$(cat "$FRAMEWORK_DIR/VERSION" 2>/dev/null || true)
  if [ -n "$clone" ]; then
    if [ "$clone" = "$AGENT_MESH_VERSION" ]; then
      echo "  Quellklon   v$clone ($FRAMEWORK_DIR)"
    else
      # Der Klon steht auf einer anderen Version als der laufende Code: das
      # Update hat geholt, aber nicht installiert. Genau der Fall, den ein
      # blosses "Version: X" verschweigt.
      echo "  Quellklon   v$clone — WEICHT AB, Installation unvollständig"
      echo "              → agent-mesh doctor"
    fi
  fi
}

# ── Übersicht ──────────────────────────────────────────────────────────────
cli_overview() {
  local group name args summary last=""
  echo "agent-mesh $AGENT_MESH_VERSION — Wissensverbund für Hermes-Agents"
  echo ""
  while IFS='|' read -r group name args summary; do
    [ -n "$group" ] || continue
    [ "$group" = "intern" ] && continue
    if [ "$group" != "$last" ]; then
      [ -n "$last" ] && echo ""
      printf '%s\n' "$group"
      last="$group"
    fi
    printf '  %-14s %s\n' "$name" "$summary"
  done << REG
$(cli_registry)
REG
  cat << 'TAIL'

  -h, --help      diese Übersicht, oder Hilfe zu einem Kommando
  -V, --version   Version, Installationsort und Zustand des Quellklons

Hilfe zu einem Kommando:  agent-mesh <kommando> --help
Zustand dieser Maschine:  agent-mesh report
Zustand des Verbunds:     agent-mesh fleet
TAIL
}

# ── Hilfe zu einem Kommando ────────────────────────────────────────────────
# Der Kurztext kommt aus der Registry, damit er nicht doppelt gepflegt wird.
# Darunter steht, was ein Kurztext nicht tragen kann: Flags und der Grund,
# warum ein Kommando sich so verhält, wie es sich verhält.
cli_cmd_help() {
  local want="$1" group name args summary found=0
  while IFS='|' read -r group name args summary; do
    [ "$name" = "$want" ] || continue
    found=1
    echo "agent-mesh $name${args:+ $args}"
    echo "  $summary"
  done << REG
$(cli_registry)
REG
  if [ "$found" = "0" ]; then
    cli_unknown "$want"
    return 2
  fi
  local detail; detail=$(cli_cmd_detail "$want")
  [ -n "$detail" ] && { echo ""; printf '%s\n' "$detail"; }
  return 0
}

cli_cmd_detail() {
  case "$1" in
    init) cat << 'D'
  Legt das age-Schlüsselpaar an, schreibt agent-mesh.conf und meldet die
  Maschine im privaten Repo an. Einmal pro Rechner.

  Danach sinnvoll:  agent-mesh sync && agent-mesh service install
D
;;
    sync) cat << 'D'
  Ein vollständiger Abgleich mit dem privaten Repo: erst pullen, dann das
  eigene Wissen (MEMORY.md, USER.md, skills/, insights/) exportieren, das
  der anderen importieren, und den eigenen Zustandsbericht veröffentlichen.

  Der Bericht wird erst in eine Temp-Datei geschrieben und geprüft, bevor er
  an seinen Platz wandert — ein misslungener Schreibvorgang liess einen
  gesunden Agent sonst für die ganze Flotte defekt aussehen.
D
;;
    converge) cat << 'D'
  --once      nur ein Durchlauf, auch wenn nichts zu tun ist (Default)
  --quiet     nur melden, wenn sich etwas geändert hat

  Ein Durchlauf stellt in fester Reihenfolge her, was gelten soll:
    1. Framework auf die Soll-Version bringen (nur signierte Releases)
    2. Wartungssignale abarbeiten
    3. Bei Änderungen im Repo: sync und automatische Antworten
    4. Relay-Warteschlange leeren

  Jeder Schritt ist idempotent — zweimal laufen lassen ändert nichts. Das ist
  der Unterschied zum Wartungs-SIGNAL, das 30 Minuten gilt und genau einmal
  wirkt: wer während des Signals nicht lief, hat es für immer verpasst.
  converge holt eine durchschlafene Nacht beim ersten Aufruf danach auf.

  Exit-Code 0 = Soll-Zustand erreicht (mit oder ohne Änderung),
            1 = ein Schritt ist gescheitert (Grund steht in der Ausgabe).
D
;;
    watch) cat << 'D'
  agent-mesh watch [sekunden]      Default: 60

  Ruft converge in einer Schleife. Für den Dauerbetrieb ist
  'agent-mesh service install' vorzuziehen — der Dienst startet nach einem
  Absturz oder Neustart von selbst wieder, eine Terminal-Schleife nicht.
  Genau daran sind am 2026-08-22 zwei Agents über Nacht hängengeblieben.
D
;;
    service) cat << 'D'
  install     Dienst einrichten und starten (systemd, launchd, Task-Scheduler)
  status      Läuft er?
  restart     Neu starten
  logs        Die letzten Zeilen
  uninstall   Entfernen

  Der Dienst startet nach Absturz und Neustart von selbst neu. Ein Agent ohne
  Dienst ist ein Agent, der nur mitbekommt, was passiert, solange jemand ein
  Terminal offen lässt.
D
;;
    update) cat << 'D'
  --check     nur nachsehen, nichts installieren
  --force     auch installieren, wenn die Remote-Version älter ist

  Installiert wird ausschliesslich ein Git-Tag, dessen Signatur gegen die
  LOKALE Vertrauensbasis (agent-mesh trust) hält — und der Inhalt kommt aus
  dem Tag, nicht aus main. Wer ins Repo schreiben kann, erreicht damit noch
  keine einzige Maschine.

  Ein Rückschritt der Versionsnummer wird abgelehnt: ein manipuliertes main
  könnte sonst auf ein altes, gültig signiertes Release zeigen und eine
  geflickte Lücke wieder aufreissen.
D
;;
    trust) cat << 'D'
  --show      die aktuell vertrauten Signaturschlüssel anzeigen

  Beim ersten Mal wird die Vertrauensbasis übernommen und laut benannt. Jede
  spätere ÄNDERUNG ist ein Ereignis, das ein Mensch bestätigen muss — sonst
  wäre sie per Broadcast austauschbar und die ganze Signaturkette wertlos.
  Fingerabdrücke vorher über einen zweiten Kanal abgleichen.
D
;;
    doctor) cat << 'D'
  --fix        nur die nachweislich gefahrlosen Reparaturen
  --security   Schwerpunkt Sicherheit (Rechte, Trust, Parallelinstallationen)
  --vault      Schwerpunkt Vault (Empfänger, Pins, Entschlüsselbarkeit)
  --net        Schwerpunkt Erreichbarkeit

  --fix macht genau zwei Dinge: private Schlüsseldateien auf 600 setzen und
  die seit v1.13.0 funktionslose AGENT_MESH_RELAY_TOKEN-Zeile entfernen (mit
  .bak). Beides ist beweisbar harmlos, deshalb darf es auch per Wartungslauf
  laufen. Alles mit Urteilsbedarf — eine Installation überschreiben, einen
  Schlüsselwechsel annehmen, Dienste neu starten — wird nur BENANNT.
D
;;
    report) cat << 'D'
  --json      maschinenlesbar (das Format, das 'fleet' einsammelt)

  Nur nachprüfbare Beobachtungen, keine Prosa. Entstanden, weil beim ersten
  Flotten-Rollout vier Berichte Zustände beschrieben, die es nicht gab —
  nicht aus Nachlässigkeit, sondern weil die Werkzeuge meldeten, was sie
  TATEN, statt was dabei herauskam.
D
;;
    fleet) cat << 'D'
  Sammelt die Berichte, die alle Agents beim sync veröffentlichen. Fragt
  niemanden — zeigt, was jeder über sich selbst berichtet hat, und wie alt
  diese Aussage ist.

  Die Spalte BERICHT ist die wichtigste: ein alter Bericht heisst, dass dort
  nichts mehr läuft. Ein Agent, der seit Stunden schweigt, bekommt kein
  Wartungssignal, kein Update und keine Nachricht mit.
D
;;
    maintenance) cat << 'D'
  --dry-run   nur zeigen, wer benachrichtigt würde

  Übertragen wird ausschliesslich das Wort "self-update". WAS daraufhin
  passiert, steht fest im Code des Empfängers und ist vom Absender nicht
  beeinflussbar: die Nachricht ist ein SIGNAL, kein BEFEHL. Ein Kanal für
  beliebige Kommandos wäre genau die Fernsteuerung, die dieses Projekt mit
  seinem ganzen Signaturapparat ausschliesst.

  Drei Schranken, jede für sich ausreichend: geprüfte Signatur, Absender in
  MAINTENANCE_FROM (Default: nur der Hub), höchstens 30 Minuten alt und
  genau einmal wirksam.

  Das Signal beschleunigt nur. Wer es verpasst, zieht beim nächsten converge
  von selbst nach — verlassen muss man sich darauf also nicht.
D
;;
    vault) cat << 'D'
  set <key> <wert>     Secret verschlüsselt ablegen (für alle Agents lesbar)
  get <key>            Mit dem eigenen Schlüssel entschlüsseln
  list                 Alle Schlüsselnamen, ohne Werte
  add-key <agent>      Einen Agent als Empfänger aufnehmen
  revoke <agent>       Einen Agent entfernen und OHNE ihn neu verschlüsseln
  pins                 Gepinnte Empfängerschlüssel und Abweichungen
  repin <agent>        Einen echten Schlüsselwechsel annehmen

  Ein gepinnter Schlüssel, der sich ändert, wird nie still übernommen: das
  ist entweder ein legitimer Wechsel oder ein Angreifer, der sich selbst zum
  Empfänger macht. Vorher über einen zweiten Kanal abgleichen.
D
;;
    send|broadcast) cat << 'D'
  Die Nachricht wird für die Empfänger verschlüsselt und signiert und über
  das private Repo zugestellt — keine offenen Ports, keine Serverkomponente.
  Läuft ein Relay, kommt sie in Sekunden an, sonst beim nächsten converge.
D
;;
    role) cat << 'D'
  hub          Zentraler Knoten: darf routen und Wartungssignale geben
  worker       Normaler Agent
  specialist   Agent mit einem benannten Schwerpunkt

  Die Rolle steht in der Agent-Karte und ist für alle sichtbar (agents).
D
;;
    peer-recv|maintenance-run) cat << 'D'
  Wird vom watch-Dienst aufgerufen. Von Hand nur zum Nachsehen sinnvoll.
D
;;
    *) return 0 ;;
  esac
}

# ── Unbekanntes Kommando ───────────────────────────────────────────────────
# "Usage: {a|b|c|…}" zwingt den Menschen, 24 Namen mit dem zu vergleichen, was
# er getippt hat. Billiger ist, das Werkzeug vergleichen zu lassen.
cli_suggest() {
  local want="$1" c best="" bestscore=0 score i len ca cb
  for c in $(cli_known_commands); do
    # Gemeinsame Präfixlänge — reicht für Tippfehler am Wortende und für
    # Abkürzungen, und kommt ohne Levenshtein in bash 3.2 aus.
    score=0; len=${#want}; [ ${#c} -lt "$len" ] && len=${#c}
    i=0
    while [ "$i" -lt "$len" ]; do
      ca=$(printf '%s' "$want" | cut -c$((i+1)))
      cb=$(printf '%s' "$c" | cut -c$((i+1)))
      [ "$ca" = "$cb" ] || break
      score=$((score+1)); i=$((i+1))
    done
    # Enthaltensein zählt auch: "maint" → "maintenance"
    case "$c" in *"$want"*) score=$((score+2)) ;; esac
    if [ "$score" -gt "$bestscore" ]; then bestscore=$score; best=$c; fi
  done
  [ "$bestscore" -ge 2 ] && echo "$best"
}

cli_unknown() {
  local want="$1" guess
  echo "❌ Unbekanntes Kommando: '$want'" >&2
  guess=$(cli_suggest "$want")
  [ -n "$guess" ] && echo "   Meintest du 'agent-mesh $guess'?" >&2
  echo "   Alle Kommandos: agent-mesh --help" >&2
}
