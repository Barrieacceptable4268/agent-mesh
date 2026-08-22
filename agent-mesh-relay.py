#!/usr/bin/env python3
"""
agent-mesh-relay — WebSocket-Relay für Echtzeit-Nachrichten zwischen Agents.

Architektur (2026-08-22, User-Entscheidung):
  - Git bleibt die Daten-Ebene (Memories/Vault/Skills) + Fallback
  - WebSocket = Nachrichten-Ebene (sofortige Zustellung, NAT-freundlich)

Prinzip:
  - Agents verbinden sich OUTBOUND zum Hub-Relay (kein Port-Forwarding nötig!)
  - Authentifizierung: Token (Agent-Name + HMAC) beim Connect
  - Nachrichten bleiben sops-verschlüsselt (der Relay sieht nur Blobs)
  - Zustellung: sofort an den Ziel-Agent (falls online), sonst offline-Queue
  - Fallback: Git bleibt — send nutzt Peer, bei Fehler Git

Usage:
  python3 agent-mesh-relay.py [--port 8766] [--token SECRET] [--queue-dir /var/lib/agent-mesh-relay]

Auth-Protokoll (Connect):
  {"type": "auth", "agent": "<name>", "token": "<HMAC-SHA256(agent, secret)>"}

Nachrichten-Protokoll:
  {"type": "msg", "to": "<agent>", "blob": "<sops-encrypted-base64>"}   # Sender→Relay
  {"type": "msg", "from": "<agent>", "blob": "<...>"}                    # Relay→Empfänger
  {"type": "ping"} / {"type": "pong"}
"""

import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import logging
import os
import sys
import time

# websockets importieren (mit klarer Fehlermeldung)
try:
    import websockets
except ImportError:
    print("❌ 'websockets' fehlt — installieren: pip install websockets", file=sys.stderr)
    sys.exit(1)

log = logging.getLogger("agent-mesh-relay")

class Relay:
    def __init__(self, secret: str, queue_dir: str):
        self.secret = secret.encode()
        self.queue_dir = queue_dir
        os.makedirs(queue_dir, exist_ok=True)
        self.clients: dict[str, set] = {}   # agent → set(websocket)
        self.offline: dict[str, list] = {}  # agent → [(ts, msg)]

    # ── Auth ──
    def check_auth(self, agent: str, token: str) -> bool:
        expected = hmac.new(self.secret, agent.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected, token)

    # ── Queue (Offline-Nachrichten) ──
    def queue_path(self, agent: str) -> str:
        return os.path.join(self.queue_dir, f"{agent}.jsonl")

    def save_offline(self, agent: str, msg: dict):
        with open(self.queue_path(agent), "a") as f:
            f.write(json.dumps({"ts": time.time(), "msg": msg}) + "\n")

    def load_offline(self, agent: str) -> list:
        path = self.queue_path(agent)
        if not os.path.exists(path):
            return []
        msgs = []
        with open(path) as f:
            for line in f:
                try:
                    msgs.append(json.loads(line)["msg"])
                except Exception:
                    continue
        os.remove(path)  # Queue nach Laden leeren
        return msgs

    # ── Zustellung ──
    async def deliver(self, agent: str, msg: dict):
        targets = self.clients.get(agent, set())
        if targets:
            # An alle Verbindungen des Agents senden
            dead = []
            for ws in list(targets):
                try:
                    await ws.send(json.dumps(msg))
                except Exception:
                    dead.append(ws)
            for ws in dead:
                targets.discard(ws)
        else:
            self.save_offline(agent, msg)

    # ── Verbindungs-Handler ──
    async def handle(self, ws):
        agent = None
        try:
            async for raw in ws:
                try:
                    data = json.loads(raw)
                except Exception:
                    continue
                mtype = data.get("type")

                if mtype == "auth":
                    name, token = data.get("agent", ""), data.get("token", "")
                    if not self.check_auth(name, token):
                        await ws.send(json.dumps({"type": "error", "error": "auth_failed"}))
                        await ws.close()
                        return
                    agent = name
                    self.clients.setdefault(agent, set()).add(ws)
                    log.info("🔗 %s verbunden (%d online)", agent, len(self.clients))
                    # Online-Bestätigung
                    await ws.send(json.dumps({"type": "auth_ok", "agent": agent}))
                    # Offline-Queue zustellen
                    for m in self.load_offline(agent):
                        await ws.send(json.dumps(m))
                    # Andere Agents benachrichtigen (Presence)
                    for other, conns in list(self.clients.items()):
                        if other != agent:
                            for c in conns:
                                try:
                                    await c.send(json.dumps({"type": "presence", "agent": agent, "status": "online"}))
                                except Exception:
                                    pass

                elif mtype == "msg":
                    if not agent:
                        continue
                    to = data.get("to", "")
                    blob = data.get("blob", "")
                    if not to or not blob:
                        continue
                    # Nachricht weiterleiten (Blob bleibt verschlüsselt!)
                    log.info("📨 %s → %s (%d B)", agent, to, len(blob))
                    await self.deliver(to, {"type": "msg", "from": agent, "blob": blob, "ts": time.time()})

                elif mtype == "ping":
                    await ws.send(json.dumps({"type": "pong"}))

        except websockets.exceptions.ConnectionClosed:
            pass
        except Exception as e:
            log.warning("⚠️  %s: %s", agent or "?", e)
        finally:
            if agent and agent in self.clients:
                self.clients[agent].discard(ws)
                if not self.clients[agent]:
                    del self.clients[agent]
                    log.info("🔌 %s getrennt (%d online)", agent, len(self.clients))
                    # Presence-Update
                    for other, conns in list(self.clients.items()):
                        for c in conns:
                            try:
                                await c.send(json.dumps({"type": "presence", "agent": agent, "status": "offline"}))
                            except Exception:
                                pass

async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--token", default=os.environ.get("AGENT_MESH_RELAY_TOKEN", ""))
    ap.add_argument("--queue-dir", default="/var/lib/agent-mesh-relay")
    args = ap.parse_args()

    if not args.token:
        print("❌ --token fehlt (oder AGENT_MESH_RELAY_TOKEN)", file=sys.stderr)
        sys.exit(1)

    logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(message)s", datefmt="%H:%M:%S")
    relay = Relay(args.token, args.queue_dir)
    log.info("🚀 Agent-Mesh-Relay auf ws://%s:%d (%d Agents online)", args.host, args.port, len(relay.clients))
    async with websockets.serve(relay.handle, args.host, args.port, max_size=2_000_000):
        await asyncio.Future()  # läuft für immer

if __name__ == "__main__":
    asyncio.run(main())
