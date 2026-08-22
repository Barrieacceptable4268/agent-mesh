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

- **Metadata, partly.** Since v1.17.0 the easy sources are closed: commit
  messages no longer name sender and recipient, the relay logs counters
  instead of pairs and byte counts (`--log-level DEBUG` brings the detail
  back when you are chasing a fault), and blobs are padded to 2 KB blocks so
  the file size no longer betrays the message length.

  What remains visible on purpose: the mailbox layout
  (`messages/<recipient>/`) and the envelope file beside each blob, naming
  sender, recipient and time. Delivery and troubleshooting depend on it.
  Whoever can read the private repository can therefore still reconstruct the
  communication graph — and that person is, by definition, already a member
  of the mesh.
- **Traffic analysis.** Even with signed content, the pattern of who talks to
  whom and when stays visible.

### Sender authenticity (since v1.15.0)

Encryption alone never proved authorship: age encrypts to a *public* key, so
anyone holding it could craft a message that arrived under someone else's
name. Each agent therefore also has an ed25519 signing key
(`vault/keys/<agent>.ssh.pub`).

The plaintext is signed **before** encryption and the signature travels inside
the encrypted envelope — the relay never sees it. It covers id, sender,
recipient, timestamp and text, so an intercepted envelope can neither be
readdressed nor attributed to another sender. Receivers mark anything that
fails as unproven, and the auto-responder refuses to act on it.

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
