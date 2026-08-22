# Onboarding: add a new machine as a mesh agent

1. **Prerequisites** (see README): git SSH key on GitHub, `age`, `sops`, `hermes`.
2. **Repo access**: the agent needs push access to the private
   `moinsen-dev/agent-mesh-memories` repo (invite its SSH key as a collaborator).
3. **Install the framework**:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/moinsen-dev/agent-mesh/main/mesh -o /usr/local/bin/mesh
   chmod +x /usr/local/bin/mesh
   ```
4. **Initialize** (unique agent name, e.g. hostname):
   ```bash
   mesh init <agent-name>
   ```
   Creates: age key pair, `~/.hermes-mesh/mesh.conf`, clones both repos.
5. **Push the first registration**:
   ```bash
   mesh sync
   ```
   → creates `agents/<name>/` + `vault/keys/<name>.age.pub`.
6. **Test vault access**:
   ```bash
   mesh vault list    # should show the shared secrets
   mesh vault get <some-secret>
   ```
   (If the vault was encrypted before this agent joined, an existing agent
   must re-set one secret once — then the new key becomes a recipient.)
7. **Set up the cron** (fallback; webhook replaces it on the hub):
   ```bash
   echo "0 6 * * * root /usr/local/bin/mesh sync >> /var/log/mesh-sync.log 2>&1" \
     > /etc/cron.d/mesh-sync
   ```
8. **Assign a role** (default is `worker`):
   ```bash
   mesh role hub        # only ONE hub per mesh (central point of contact)
   mesh role specialist # domain expert, e.g. media, db, web
   ```

## Rules for agents

- **Never put secrets in memories/insights** — vault only.
- **Skills**: `mesh sync` exports agent-created skills only (from
  `~/.hermes/skills/.usage.json`, `created_by: agent`).
- **Conflicts**: `mesh sync` does `git pull --rebase` — resolve conflicts
  manually if two agents changed the same file simultaneously.
- **Mesh health**: `mesh status` shows all agents + vault status.
- **Real-time**: the hub's webhook triggers sync instantly on every push;
  other agents can also run `mesh-webhook.py` + tunnel if they want the same.
