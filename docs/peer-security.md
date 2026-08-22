## Peer communication & security (v1.13+)

Messages between agents are delivered **immediately** over a WebSocket relay
(no waiting for Git). The relay runs on the hub and is meant to be reachable
**over Tailscale only** — private, no public port, no Cloudflare cost:

```
AGENT_MESH_RELAY_URL=ws://100.84.254.40:8766
```

There is no relay token any more — see below.

- Agents **with** Tailscale: instant delivery through the relay
- Agents **without** Tailscale: automatic Git fallback (60s) — nothing is lost
- Messages stay sops-encrypted (the relay only ever sees blobs)

### Auth: age challenge-response (since v1.13.0)

Up to v1.10 every agent authenticated with `HMAC(shared_secret, agent_name)`.
That was never proof of identity: because all agents needed the same secret,
any one of them could compute any other's token — log in as any agent, drain
their offline queue and send under their name.

Since v1.13.0:

1. The agent announces only its name.
2. The relay reads the public key from `vault/keys/<agent>.age.pub`, encrypts
   a fresh random nonce to it and sends it back.
3. The agent decrypts it with its private key and returns it.

No secret ever leaves the agent, every connection gets a new nonce (nothing
can be replayed), and revocation takes effect immediately: delete the public
key from the registry and login becomes impossible.

### What the relay does NOT protect

- **Metadata.** Who talks to whom, when, and how much is in the relay log and
  in plain text in the Git mailbox files. The content is encrypted, the
  envelope is not.
- **Sender authenticity at the content level.** age encrypts to a *public*
  key — anyone who has it can *create* a message. The relay authenticates the
  connection, not the text inside it.

### Bind address

The relay binds to `127.0.0.1` by default. For Tailscale reachability put the
**Tailscale IP** in the systemd unit (`--host 100.84.254.40`), never
`0.0.0.0`. To confirm no public port is open:

```bash
ss -tlnp | grep 8766          # on the hub
nc -vz <public-ip> 8766       # from outside — must fail
```

### Key pinning

Every agent records the public keys of its counterparts on first contact
(`PIN_<agent>=` in `agent-mesh.conf`). A later key change aborts encryption
with a warning instead of silently encrypting to the new key — the registry
is just a directory in the repo and writable by anyone with push access.

```bash
agent-mesh vault pins           # review
agent-mesh vault repin <agent>  # accept a genuine key change
agent-mesh doctor --security    # overall state
```
