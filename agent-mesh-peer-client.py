#!/usr/bin/env python3
"""
agent-mesh-peer-client — verbindet sich mit dem Relay und sendet/empfängt.

Usage:
  # Senden (Einmal-Verbindung):
  python3 agent-mesh-peer-client.py --url ws://HOST:8766 --key-file ~/.agent-mesh/keys/NAME.age \
      --agent NAME --to EMPFÄNGER --blob BASE64_BLOB

  # Empfangen (Einmal-Verbindung, holt gequeued Nachrichten):
  python3 agent-mesh-peer-client.py --url ws://HOST:8766 --key-file ~/.agent-mesh/keys/NAME.age \
      --agent NAME --recv
      → Output: FROM|BASE64_BLOB (eine pro Zeile)

Auth (Security v1.2): Der Relay schickt eine Nonce, verschlüsselt an den
registrierten age-Public-Key. Wir entschlüsseln sie mit dem eigenen privaten
Key und schicken sie zurück. Es wird KEIN Geheimnis übertragen — das frühere
geteilte Relay-Token gibt es nicht mehr (jeder Agent konnte damit das Token
jedes anderen berechnen).

Der Relay routet Blobs nur weiter (bleiben sops-verschlüsselt).
"""

import argparse
import asyncio
import json
import os
import shutil
import subprocess
import sys

try:
    import websockets
except ImportError:
    print("websockets fehlt", file=sys.stderr)
    sys.exit(1)


AGE_BIN = os.environ.get("AGE_BIN", "age")


def solve_challenge(blob: str, key_file: str) -> str:
    """Die vom Relay verschlüsselte Nonce mit dem eigenen age-Key öffnen."""
    age = shutil.which(AGE_BIN) or shutil.which("age.exe")
    if not age:
        print("age fehlt — Relay-Auth nicht möglich", file=sys.stderr)
        sys.exit(1)
    r = subprocess.run([age, "--decrypt", "--identity", key_file],
                       input=blob.encode(), capture_output=True, timeout=15)
    if r.returncode != 0:
        print(f"Challenge nicht lösbar: {r.stderr.decode(errors='replace').strip()}",
              file=sys.stderr)
        sys.exit(1)
    return r.stdout.decode().strip()


async def authenticate(ws, agent: str, key_file: str):
    """auth → challenge → auth_resp → auth_ok."""
    await ws.send(json.dumps({"type": "auth", "agent": agent}))
    ch = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
    if ch.get("type") != "challenge":
        print(f"auth failed: {ch}", file=sys.stderr)
        sys.exit(1)
    nonce = solve_challenge(ch["blob"], key_file)
    await ws.send(json.dumps({"type": "auth_resp", "nonce": nonce}))
    resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
    if resp.get("type") != "auth_ok":
        print(f"auth failed: {resp}", file=sys.stderr)
        sys.exit(1)


async def send_one(url, key_file, agent, to, blob):
    async with websockets.connect(url, max_size=2_000_000) as ws:
        await authenticate(ws, agent, key_file)
        await ws.send(json.dumps({"type": "msg", "to": to, "blob": blob}))
        # kurzes ack-window
        try:
            await asyncio.wait_for(ws.recv(), timeout=1)
        except Exception:
            pass
    print("sent")


async def recv_one(url, key_file, agent):
    async with websockets.connect(url, max_size=2_000_000) as ws:
        await authenticate(ws, agent, key_file)
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
    ap.add_argument("--key-file", required=True,
                    help="eigener privater age-Key (~/.agent-mesh/keys/<agent>.age)")
    ap.add_argument("--agent", required=True)
    ap.add_argument("--to")
    ap.add_argument("--blob")
    ap.add_argument("--recv", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.key_file):
        print(f"Key-Datei fehlt: {args.key_file}", file=sys.stderr)
        sys.exit(1)
    if args.recv:
        asyncio.run(recv_one(args.url, args.key_file, args.agent))
    else:
        if not args.to or not args.blob:
            print("--to und --blob nötig (oder --recv)", file=sys.stderr)
            sys.exit(1)
        asyncio.run(send_one(args.url, args.key_file, args.agent, args.to, args.blob))


if __name__ == "__main__":
    main()
