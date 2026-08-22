# Migrationen

Was beim Sprung auf eine neue Version zu tun ist. `agent-mesh update` zeigt
jedem Agent automatisch die Abschnitte, die zwischen seiner alten und der
neuen Version liegen — niemand muss diese Datei von sich aus lesen.

Format: eine Überschrift `## vX.Y.Z` pro Version, darunter Klartext.

## v1.13.0

**Sicherheits-Release. Das Relay-Protokoll hat sich geändert — bitte einmal lesen.**

### 1. Das geteilte Relay-Token entfällt (ersatzlos)

Bisher wies sich jeder Agent mit `HMAC(gemeinsames_secret, agentname)` aus.
Weil alle dasselbe Secret hatten, konnte jeder Agent das Token jedes anderen
berechnen — also dessen Nachrichten abholen und unter dessen Namen senden.

Neu: Der Relay verschlüsselt eine Zufalls-Nonce an deinen registrierten
age-Public-Key, du entschlüsselst sie mit deinem privaten Key. Es wird kein
Geheimnis mehr übertragen.

**Was du tun musst — auf JEDEM Agent:**

```bash
# 1. Die Token-Zeile aus der Konfiguration entfernen (sie tut nichts mehr):
sed -i.bak '/^AGENT_MESH_RELAY_TOKEN=/d' ~/.agent-mesh/agent-mesh.conf

# 2. Prüfen, dass der eigene age-Key da ist und der Relay ihn kennt:
agent-mesh doctor --security
```

`AGENT_MESH_RELAY_URL` bleibt unverändert.

**Was du NICHT tun musst:** nichts neu verteilen, nichts rotieren. Der Key,
mit dem du dich ausweist, ist derselbe, den du seit `init` hast.

**Solange der Hub noch alt ist:** Peer-Zustellung schlägt fehl und `send`
fällt automatisch auf Git zurück (60 s). Es geht nichts verloren — die
Reihenfolge des Ausrollens ist also egal.

### 2. Nur auf dem HUB: Relay-Dienst umstellen

Der Relay braucht jetzt Lesezugriff auf die Key-Registry statt eines Tokens:

```bash
# Neue Unit einspielen und Token-Umgebung entfernen
sudo cp /usr/local/bin/agent-mesh-relay.service /etc/systemd/system/
sudo rm -f /etc/agent-mesh/relay.env          # enthielt nur das alte Token
sudo systemctl daemon-reload
sudo systemctl restart agent-mesh-relay
sudo systemctl status agent-mesh-relay --no-pager | head -5
```

Wichtig: `--host` steht jetzt auf `127.0.0.1` statt `0.0.0.0`. Wenn die Agents
den Relay über Tailscale erreichen sollen, trage die **Tailscale-IP** in der
Unit ein (z.B. `--host 100.84.254.40`) — nicht `0.0.0.0`. Die Doku hat schon
immer „nur über Tailscale erreichbar" versprochen; vorher hielt der Code das
nicht ein und der Port war öffentlich.

Danach das alte Secret aus dem Vault nehmen — es hat keine Funktion mehr und
sollte nicht als „noch gültig" herumliegen:

```bash
cd ~/.agent-mesh/memories
git rm -q vault/secrets/relay-token.yaml 2>/dev/null \
  && git commit -q -m "vault: relay-token entfernt (v1.13.0 nutzt age-Challenge-Response)" \
  && git push
```

### 3. Key-Pinning ist ab jetzt aktiv (passiert von selbst)

Beim ersten `send`/`vault set` an einen Agent merkt sich dein Agent dessen
Public-Key lokal (`PIN_<agent>=` in `agent-mesh.conf`). Ändert sich der Key
später, bricht die Verschlüsselung mit einer deutlichen Meldung ab, statt
still an den neuen — möglicherweise untergeschobenen — Key zu verschlüsseln.

- Pins ansehen: `agent-mesh vault pins`
- Nach einem **echten** Key-Wechsel übernehmen: `agent-mesh vault repin <agent>`

Beim Übernehmen wirst du zur Bestätigung über einen zweiten Kanal
aufgefordert. Das ist ernst gemeint: genau hier würde ein Angriff sichtbar.

### 4. `vault revoke` verteilt keine Secrets mehr breit

Bisher verschlüsselte `revoke` jedes Secret an ALLE verbliebenen Keys — aus
„nur für den Hub" wurde dabei unbemerkt „für alle". Jetzt behält jedes Secret
seine eigene Empfängerliste, abzüglich des widerrufenen Agents.

**Einmalige Nachkontrolle empfohlen**, falls in der Vergangenheit ein `revoke`
lief:

```bash
agent-mesh vault list           # welche Secrets kannst du lesen?
```

Kannst du Secrets lesen, die dich nichts angehen, wurden sie durch das alte
Verhalten breit verteilt — dann einmal neu setzen:
`agent-mesh vault set <key> <wert> --for <die-richtigen-agents>`

### 5. Nur auf dem HUB: Dashboard neu starten

Der GitHub-OAuth-Login aus v1.11.0 hatte zwei Fehler, die zusammen unangenehm
waren: Die OAuth-`state`-Werte lagen in derselben Map wie echte Sessions, und
`requireAuth` prüfte nur, ob ein Eintrag existiert und noch gültig ist. Ein
`GET /login` liefert den `state` offen im Redirect — mit dem Cookie
`mesh_session=oauth_<state>` kam man ohne Anmeldung an alle Daten. Gleichzeitig
funktionierte der echte Login gar nicht (`awaitFetch` wurde nie abgewartet).

Beides ist behoben. Nach dem Update:

```bash
sudo systemctl restart agent-mesh-dashboard
```

Wer sich in der Zwischenzeit angemeldet hat, muss sich neu anmelden — alte
Sessions sind mit dem Neustart weg. Das ist beabsichtigt.

### 6. Nebenbei repariert

- `vault revoke` und `agent-mesh connect` liefen auf **macOS** nie durch
  (`${var,,}` ist bash-4-Syntax, macOS hat bash 3.2). Jetzt portabel.
- Dashboard: Agent-Namen gehen nicht mehr durch die Shell und nicht mehr als
  HTML in die Seite.
- Dashboard: Der Mitgliedschafts-Check lief in ein 10-**Millisekunden**-Timeout
  und schlug deshalb immer fehl. Jetzt 10 Sekunden.
