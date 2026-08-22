# Onboarding: Neuen Rechner als Agent ins Mesh aufnehmen

1. **Voraussetzungen** (siehe README): Git-SSH-Key auf GitHub, `age`, `sops`, `hermes`.
2. **Repo-Rechte**: Der Agent braucht Push-Zugriff auf das private
   `moinsen-dev/agent-mesh-memories`-Repo (SSH-Key als Collaborator einladen).
3. **Framework installieren**:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/mesh -o /usr/local/bin/mesh
   chmod +x /usr/local/bin/mesh
   ```
4. **Initialisieren** (eindeutiger Agent-Name, z.B. Hostname):
   ```bash
   mesh init <agent-name>
   ```
   Erzeugt: age-Keypaar, `~/.hermes-mesh/mesh.conf`, klont beide Repos.
5. **Erste Registrierung pushen**:
   ```bash
   mesh sync
   ```
   → legt `agents/<name>/` + `vault/keys/<name>.age.pub` an.
6. **Vault-Zugriff testen**:
   ```bash
   mesh vault list    # sollte die geteilten Secrets zeigen
   mesh vault get <irgendein-secret>
   ```
   (Falls das Vault vor diesem Agent verschlüsselt wurde, muss einmalig ein
   bestehender Agent das Secret neu setzen — dann ist der neue Key Empfänger.)
7. **Cron einrichten**:
   ```bash
   echo "0 6 * * * root /usr/local/bin/mesh sync >> /var/log/mesh-sync.log 2>&1" \
     > /etc/cron.d/mesh-sync
   ```

## Regeln für Agents

- **Nie Secrets in Memories/Insights** — nur ins Vault.
- **Skills**: `mesh sync` exportiert nur agent-erstellte Skills (aus
  `~/.hermes/skills/.usage.json`, `created_by: agent`).
- **Konflikte**: `mesh sync` macht `git pull --rebase` — bei Konflikten
  manuell lösen (gleiche Datei von zwei Agents gleichzeitig geändert).
- **Mesh-Gesundheit**: `mesh status` zeigt alle Agents + Vault-Status.
