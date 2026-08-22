# Agent-Mesh

Verbinde mehrere **Hermes-Agents** zu einem Wissens-Verbund: Sie tauschen
Memories, Skills und Insights aus und teilen Secrets über ein verschlüsseltes
Vault — „gegenseitig schlau machen" für deine Rechner-Flotte.

```
┌─────────────────────────────────────────────┐
│  agent-mesh-memories (PRIVATE Repo)         │
│  ┌──────────┬──────────┬──────────────────┐ │
│  │ agents/  │ agents/  │ vault/          │ │
│  │ ax41/    │ macbook/ │  secrets.yaml   │ │
│  │  MEMORY  │  ...     │  (sops+age,     │ │
│  │  skills/ │          │   verschlüsselt)│ │
│  └──────────┴──────────┴──────────────────┘ │
└──────────────┬──────────────────────────────┘
               │ git pull / push (Cron)
     ┌─────────┴─────────┐
     │ Hermes Agent AX41 │    │ Hermes Agent Mac │
     └───────────────────┘    └──────────────────┘
```

- **Public-Repo** (`agent-mesh`): dieses Framework — jeder kann es nutzen.
- **Private-Repo** (`agent-mesh-memories`): die Daten (Memories/Skills/Vault).
  Memories sind persönlich — niemals ins public Repo.

## Voraussetzungen (pro Rechner)

- Git + SSH-Key auf GitHub (git@github.com)
- `age` und `sops` (Vault)
- `hermes` (für den Wissen-Export; ohne Hermes geht nur Git-Sync)

```bash
# Debian/Ubuntu:
apt install age
curl -fsSL -o /tmp/sops.deb https://github.com/getsops/sops/releases/latest/download/sops_3.13.3_amd64.deb
dpkg -i /tmp/sops.deb
```

## Schnellstart (ein Rechner = ein Agent)

```bash
curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/mesh -o /usr/local/bin/mesh
chmod +x /usr/local/bin/mesh

mesh init <agent-name>        # z.B. "ax41" oder "macbook"
mesh sync                     # Wissen exportieren + pushen (Cron: täglich)
mesh status                   # Wer ist im Mesh?
```

## Vault (geteilte Secrets)

Jeder Agent hat einen eigenen **age-Key** (`~/.hermes-mesh/keys/<name>.age`,
600er, nie committen). Secrets werden mit den Public-Keys **aller** Agents
verschlüsselt → jeder kann lesen, niemand ohne Key.

```bash
mesh vault set DB_PASSWORD "geheim"   # verschlüsselt ablegen (alle Agents)
mesh vault get DB_PASSWORD            # mit eigenem Key entschlüsseln
mesh vault list                       # Schlüsselnamen anzeigen
```

⚠ **Sicherheit:** Das Vault-Repo ist privat. Trotzdem gilt: Secrets gehören
nur ins Vault, nie in Memory/Insights.

## Insights (Erkenntnisse teilen)

```bash
mesh insight add "GH-8: preparation: wird ignoriert, profiles_ch: ist Pflicht"
```

→ landet als Markdown unter `agents/<name>/insights/` und ist für alle Agents
im Mesh sichtbar (beim nächsten `mesh sync`).

## Automatisierung (Cron)

```bash
# täglich 06:00: pull → export → push
echo "0 6 * * * root /usr/local/bin/mesh sync >> /var/log/mesh-sync.log 2>&1" \
  > /etc/cron.d/mesh-sync
```

## Onboarding für neue Agents

Siehe [docs/ONBOARDING.md](docs/ONBOARDING.md).

## Datenschutz-Hinweis

- **Public**: Framework-Code. Keine persönlichen Daten.
- **Private**: Memories/Skills/Insights/Vault. Persönlich, nie public machen.
- Der Profile-Export von Hermes redigiert Secrets automatisch
  (`_EXPORT_REDACT_NAMES`), zusätzlich filtert `mesh sync` nur agent-erstellte
  Skills.
