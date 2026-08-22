## Peer-Kommunikation & Sicherheit (v1.13+)

Nachrichten zwischen Agents gehen **sofort** über einen WebSocket-Relay (kein
Git-Warten). Der Relay läuft auf dem Hub und soll **nur über Tailscale**
erreichbar sein (privat, kein öffentlicher Port, keine Cloudflare-Kosten):

```
AGENT_MESH_RELAY_URL=ws://100.84.254.40:8766
```

Ein Relay-Token gibt es nicht mehr — siehe unten.

- Agents **mit** Tailscale: sofortige Zustellung via Relay
- Agents **ohne** Tailscale: automatischer Git-Fallback (60s) — kein Verlust
- Nachrichten bleiben sops-verschlüsselt (Relay sieht nur Blobs)

### Auth: age-Challenge-Response (seit v1.13.0)

Bis v1.10 wies sich jeder Agent mit `HMAC(gemeinsames_secret, agentname)` aus.
Das war kein Identitätsnachweis: Weil alle Agents dasselbe Secret brauchten,
konnte jeder das Token jedes anderen berechnen — und sich als beliebiger Agent
anmelden, dessen Offline-Queue leeren und unter dessen Namen senden.

Seit v1.13.0:

1. Agent meldet nur seinen Namen an.
2. Der Relay zieht den Public-Key aus `vault/keys/<agent>.age.pub`,
   verschlüsselt eine frische Zufalls-Nonce daran und schickt sie zurück.
3. Der Agent entschlüsselt sie mit seinem privaten Key und sendet sie zurück.

Damit verlässt kein Geheimnis je den Agent, jede Verbindung hat eine neue
Nonce (nichts ist wiederspielbar), und ein Widerruf wirkt sofort: Public-Key
aus der Registry gelöscht → Login unmöglich.

### Was der Relay NICHT schützt

- **Metadaten.** Wer wem wann wie viel schickt, steht im Relay-Log und im
  Klartext in den Git-Mailbox-Dateien. Verschlüsselt ist der Inhalt, nicht der
  Umschlag.
- **Absender-Echtheit auf Inhaltsebene.** age verschlüsselt an einen
  öffentlichen Key — wer den kennt, kann eine Nachricht *erzeugen*. Der Relay
  authentifiziert die Verbindung, nicht den Text darin.

### Bind-Adresse

Der Relay bindet standardmäßig auf `127.0.0.1`. Für Tailscale-Erreichbarkeit
gehört die **Tailscale-IP** in die systemd-Unit (`--host 100.84.254.40`),
nicht `0.0.0.0`. Zum Prüfen, dass wirklich kein öffentlicher Port offen ist:

```bash
ss -tlnp | grep 8766          # auf dem Hub
nc -vz <öffentliche-ip> 8766  # von aussen — muss scheitern
```

### Key-Pinning

Jeder Agent merkt sich die Public-Keys der Gegenstellen beim ersten Kontakt
(`PIN_<agent>=` in `agent-mesh.conf`). Ein späterer Key-Wechsel bricht die
Verschlüsselung mit einer Warnung ab, statt still an den neuen Key zu
verschlüsseln — die Registry ist nur ein Verzeichnis im Repo und für jeden
mit Push-Recht beschreibbar.

```bash
agent-mesh vault pins           # Stand ansehen
agent-mesh vault repin <agent>  # echten Key-Wechsel übernehmen
agent-mesh doctor --security    # Gesamtstand prüfen
```
