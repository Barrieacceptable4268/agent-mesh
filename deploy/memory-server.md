# A shared memory for the mesh

The mesh's knowledge used to be MEMORY.md files copied into a git repo: not
queryable, and until v1.29.0 nobody read them. Hermes has a designed slot for
external memory — this is how to fill it with a server all agents share.

**Why a central server fits this mesh:** the server must be reachable from
every agent, but no agent has to be reachable. Machines behind NAT can join.
That is exactly what peer-to-peer approaches cannot do here.

## What runs where

    hetzner / ax41 (public)          every agent (anywhere)
    ┌──────────────────────┐         ┌──────────────────────┐
    │ mem0 REST server     │ ◀────── │ hermes  (memory:     │
    │ + vector store       │  HTTPS  │          provider     │
    │ X-API-Key            │  out    │          mem0)        │
    └──────────────────────┘  only   └──────────────────────┘

Hermes talks to it over four endpoints — `POST /search`, `POST /memories`,
`PUT /memories/{id}`, `DELETE /memories/{id}`, authenticated with `X-API-Key`.
Anything serving that contract will do; mem0 OSS is the reference.

Identities are what make it a *mesh* memory rather than six private ones:

    user_id   = the human      — the same for every agent, so it is one memory
    agent_id  = the machine    — so you can still see who contributed what

## Bring the server up

On a machine that is publicly reachable (here: the Hetzner box). Pick a real
key — it is the only thing between the internet and your agents' memory.

```bash
mkdir -p /opt/mesh-memory && cd /opt/mesh-memory
export MEM0_KEY="$(openssl rand -hex 32)"
cat > docker-compose.yml << 'YAML'
services:
  mem0:
    image: mem0/mem0-api-server:latest
    restart: unless-stopped
    environment:
      - API_KEY=${MEM0_KEY}
      - OPENAI_API_KEY=${OPENAI_API_KEY}   # server-side fact extraction
      - POSTGRES_HOST=db
      - POSTGRES_USER=mem0
      - POSTGRES_PASSWORD=${DB_PASSWORD}
      - POSTGRES_DB=mem0
    ports: ["127.0.0.1:8888:8000"]
    depends_on: [db]
  db:
    image: pgvector/pgvector:pg16
    restart: unless-stopped
    environment:
      - POSTGRES_USER=mem0
      - POSTGRES_PASSWORD=${DB_PASSWORD}
      - POSTGRES_DB=mem0
    volumes: ["./pgdata:/var/lib/postgresql/data"]
YAML
docker compose up -d
```

**Do not expose port 8888 directly.** Bind it to localhost, as above, and put
it behind the reverse proxy that already terminates TLS on that host — a
Cloudflare Tunnel works equally well and needs no open port at all. The mesh
then talks to `https://memory.<your-domain>`.

Verify the contract before telling the mesh about it:

```bash
curl -fsS -X POST https://memory.<your-domain>/search \
  -H "X-API-Key: $MEM0_KEY" -H 'Content-Type: application/json' \
  -d '{"query":"probe","user_id":"probe"}'
```

A JSON body back means it is ready. `agent-mesh memory setup` runs the same
check and refuses to write anything if it fails.

## Tell the mesh, then join

Once, from any agent that has the key:

```bash
agent-mesh memory setup --host https://memory.<your-domain> --key "$MEM0_KEY"
```

This checks the server, stores the key in the **vault** encrypted for every
named agent, and records the host in the private repo. The key is never in the
clear anywhere.

Then on each machine — after its next `converge`, the host is already there:

```bash
agent-mesh memory join
agent-mesh memory status
```

## What this replaces

Not the git layer. Messages, the vault, the signature chain and the fleet view
stay where they are — git needs no reachability and works offline, which is
what makes it right for those.

What it replaces is copying knowledge as files. From here on, memory is
written and searched, not shipped.
