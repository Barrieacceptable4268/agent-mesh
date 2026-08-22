## Peer-Kommunikation & Sicherheit (v1.9+)

Nachrichten zwischen Agents gehen **sofort** über einen WebSocket-Relay (kein
Git-Warten). Der Relay läuft auf dem Hub und ist **nur über Tailscale**
erreichbar (privat, kein öffentlicher Port, keine Cloudflare-Kosten):

```
AGENT_MESH_RELAY_URL=ws://100.84.254.40:8766
AGENT_MESH_RELAY_TOKEN=<aus vault: agent-mesh vault get relay-token>
```

- Agents **mit** Tailscale: sofortige Zustellung via Relay
- Agents **ohne** Tailscale: automatischer Git-Fallback (60s) — kein Verlust
- Nachrichten bleiben sops-verschlüsselt (Relay sieht nur Blobs)
- Auth am Relay: HMAC-Token pro Agent
