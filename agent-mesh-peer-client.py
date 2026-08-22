#!/usr/bin/env python3
"""
agent-mesh-peer-client — verbindet sich mit dem Relay und sendet/empfängt.

Usage:
  # Senden (Einmal-Verbindung):
  python3 agent-mesh-peer-client.py --url ws://HOST:8766 --token TOKEN \
      --agent NAME --to EMPFÄNGER --blob BASE64_BLOB

  # Empfangen (Einmal-Verbindung, holt gequeued Nachrichten):
  python3 agent-mesh-peer-client.py --url ws://HOST:8766 --token TOKEN \
      --agent NAME --recv
      → Output: FROM|BASE64_BLOB (eine pro Zeile)

Der Relay routet Blobs nur weiter (bleiben sops-verschlüsselt).
"""

import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import sys

try:
    import websockets
except ImportError:
    print("websockets fehlt", file=sys.stderr)
    sys.exit(1)


def make_token(secret: str, agent: str) -> str:
    return hmac.new(secret.encode(), agent.encode(), hashlib.sha256).hexdigest()


async def send_one(url, token, agent, to, blob):
    async with websockets.connect(url, max_size=2_000_000) as ws:
        await ws.send(json.dumps({"type": "auth", "agent": agent, "token": make_token(token, agent)}))
        resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
        if resp.get("type") != "auth_ok":
            print(f"auth failed: {resp}", file=sys.stderr)
            sys.exit(1)
        await ws.send(json.dumps({"type": "msg", "to": to, "blob": blob}))
        # kurzes ack-window
        try:
            await asyncio.wait_for(ws.recv(), timeout=1)
        except Exception:
            pass
    print("sent")


async def recv_one(url, token, agent):
    async with websockets.connect(url, max_size=2_000_000) as ws:
        await ws.send(json.dumps({"type": "auth", "agent": agent, "token": make_token(token, agent)}))
        resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
        if resp.get("type") != "auth_ok":
            print(f"auth failed: {resp}", file=sys.stderr)
            sys.exit(1)
        # auth_ok → dann gequeued Nachrichten + evtl. presence
        try:
            while True:
                raw = await asyncio.wait_for(ws.recv(), timeout=2)
                data = json.loads(raw)
                if data.get("type") == "msg":
                    print(f"{data['from']}|{data['blob']}")
        except asyncio.TimeoutError:
            pass  # keine weiteren Nachrichten — fertig


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--token", required=True)
    ap.add_argument("--agent", required=True)
    ap.add_argument("--to")
    ap.add_argument("--blob")
    ap.add_argument("--recv", action="store_true")
    args = ap.parse_args()

    if args.recv:
        asyncio.run(recv_one(args.url, args.token, args.agent))
    else:
        if not args.to or not args.blob:
            print("--to und --blob nötig (oder --recv)", file=sys.stderr)
            sys.exit(1)
        asyncio.run(send_one(args.url, args.token, args.agent, args.to, args.blob))


if __name__ == "__main__":
    main()
