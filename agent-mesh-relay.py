#!/usr/bin/env python3
"""
agent-mesh-relay — WebSocket-Relay für Echtzeit-Nachrichten zwischen Agents.

Architektur (2026-08-22, User-Entscheidung):
  - Git bleibt die Daten-Ebene (Memories/Vault/Skills) + Fallback
  - WebSocket = Nachrichten-Ebene (sofortige Zustellung, NAT-freundlich)

Prinzip:
  - Agents verbinden sich OUTBOUND zum Hub-Relay (kein Port-Forwarding nötig!)
  - Authentifizierung: age-Challenge-Response gegen den registrierten Key
  - Nachrichten bleiben sops-verschlüsselt (der Relay sieht nur Blobs)
  - Zustellung: sofort an den Ziel-Agent (falls online), sonst offline-Queue
  - Fallback: Git bleibt — send nutzt Peer, bei Fehler Git

Auth (Security v1.2, Audit-Befund #4):
  Früher: HMAC(gemeinsames_secret, agentname). Jeder Agent brauchte dasselbe
  Secret und konnte damit das Token JEDES anderen Agents berechnen — also sich
  als beliebiger Agent ausgeben, dessen Offline-Queue leeren und unter fremdem
  Namen senden. Ein geteiltes Passwort ist keine Identität.

  Jetzt: Der Relay verschlüsselt eine Zufalls-Nonce an den age-Public-Key aus
  der Registry (vault/keys/<agent>.age.pub). Nur wer den passenden privaten
  Key besitzt, kann sie zurückschicken. Kein Geheimnis verlässt je den Agent,
  nichts ist wiederspielbar (neue Nonce pro Verbindung), und ein Widerruf
  wirkt sofort: .pub gelöscht → Login unmöglich.

Usage:
  python3 agent-mesh-relay.py [--port 8766] [--host 127.0.0.1] \
      [--keys-dir /root/.agent-mesh/memories/vault/keys] \
      [--queue-dir /var/lib/agent-mesh-relay]

Protokoll:
  → {"type":"auth","agent":"<name>"}
  ← {"type":"challenge","blob":"<age-armored>"}
  → {"type":"auth_resp","nonce":"<hex>"}
  ← {"type":"auth_ok","agent":"<name>"}
  {"type":"msg","to":"<agent>","blob":"<sops-base64>"}   Sender→Relay
  {"type":"msg","from":"<agent>","blob":"<...>"}         Relay→Empfänger
  {"type":"ping"} / {"type":"pong"}
"""

import argparse
import asyncio
import hmac
import json
import logging
import os
import re
import secrets
import shutil
import sys
import time

try:
    import websockets
except ImportError:
    print("❌ 'websockets' fehlt — installieren: pip install websockets", file=sys.stderr)
    sys.exit(1)

log = logging.getLogger("agent-mesh-relay")

# SECURITY (Audit-Befund #3): Agent-Namen landen über queue_path() in einem
# Dateipfad. os.path.join() verwirft das Präfix bei ABSOLUTEN Argumenten, und
# "../" trägt aus dem Queue-Verzeichnis heraus. Ohne Prüfung wäre jedes
# "to"-Feld ein Schreibzugriff und jeder Auth-Name ein os.remove() auf einen
# beliebigen Pfad. Deshalb: strikte Allowlist, überall.
VALID_AGENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")

AUTH_TIMEOUT = 15        # Sekunden für den gesamten Handshake (Audit-Befund D2)
MAX_QUEUE_MSGS = 500     # pro Agent (Audit-Befund D1)
MAX_QUEUE_BYTES = 32 * 1024 * 1024
QUEUE_TTL = 7 * 24 * 3600
MAX_FRAME = 256 * 1024   # 2 MB waren grosszügig für einen Nachrichten-Blob (D3)
MAX_CONN_PER_IP = 20     # Verbindungsobergrenze (D2-Rest)
MAX_CONN_PER_AGENT = 5
RATE_MSGS = 30           # Nachrichten je Fenster und Agent (D3)
RATE_WINDOW = 60.0
PRESENCE_MIN_GAP = 10.0  # Presence-Fanout ist O(n²) — nicht im Sekundentakt (D4)


def valid_agent(name) -> bool:
    return isinstance(name, str) and bool(VALID_AGENT.match(name))


class Relay:
    def __init__(self, keys_dir: str, queue_dir: str, age_bin: str):
        self.keys_dir = keys_dir
        self.queue_dir = queue_dir
        self.age_bin = age_bin
        os.makedirs(queue_dir, exist_ok=True)
        self.clients: dict[str, set] = {}
        self.conn_per_ip: dict[str, int] = {}
        self.rate: dict[str, list] = {}          # agent → [(ts), …] im Fenster
        self.last_presence: dict[str, float] = {}

    # ── Key-Registry ──
    def pubkey_for(self, agent: str) -> str | None:
        """age-Public-Key des Agents aus der Registry (vault/keys/)."""
        if not valid_agent(agent):
            return None
        path = os.path.join(self.keys_dir, f"{agent}.age.pub")
        try:
            with open(path) as f:
                key = f.read().strip()
        except OSError:
            return None
        return key if key.startswith("age1") else None

    # ── Challenge-Response ──
    async def make_challenge(self, pubkey: str, nonce: str) -> str | None:
        """Nonce an den Public-Key verschlüsseln (armored, JSON-tauglich)."""
        try:
            proc = await asyncio.create_subprocess_exec(
                self.age_bin, "--encrypt", "--armor", "--recipient", pubkey,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            out, err = await asyncio.wait_for(
                proc.communicate(nonce.encode()), timeout=10)
        except (OSError, asyncio.TimeoutError) as e:
            log.warning("⚠️  age-Verschlüsselung fehlgeschlagen: %s", e)
            return None
        if proc.returncode != 0:
            log.warning("⚠️  age beendete sich mit %s: %s",
                        proc.returncode, err.decode(errors="replace").strip())
            return None
        return out.decode()

    async def do_auth(self, ws) -> str | None:
        """Handshake. Gibt den Agent-Namen zurück — oder None bei Ablehnung."""
        raw = await ws.recv()
        try:
            data = json.loads(raw)
        except Exception:
            return None
        if data.get("type") != "auth":
            await ws.send(json.dumps({"type": "error", "error": "expected_auth"}))
            return None

        name = data.get("agent", "")
        pubkey = self.pubkey_for(name)
        if pubkey is None:
            # Kein Hinweis, ob der Name ungültig oder nur unbekannt ist.
            log.info("⛔ Auth abgelehnt: unbekannter Agent %r", name)
            await ws.send(json.dumps({"type": "error", "error": "auth_failed"}))
            return None

        nonce = secrets.token_hex(32)
        blob = await self.make_challenge(pubkey, nonce)
        if blob is None:
            await ws.send(json.dumps({"type": "error", "error": "challenge_failed"}))
            return None
        await ws.send(json.dumps({"type": "challenge", "blob": blob}))

        try:
            resp = json.loads(await ws.recv())
        except Exception:
            return None
        answer = resp.get("nonce", "")
        if not isinstance(answer, str) or not hmac.compare_digest(answer, nonce):
            log.info("⛔ Auth fehlgeschlagen: %s konnte die Challenge nicht lösen", name)
            await ws.send(json.dumps({"type": "error", "error": "auth_failed"}))
            return None
        return name

    # ── Queue (Offline-Nachrichten) ──
    def queue_path(self, agent: str) -> str:
        if not valid_agent(agent):
            raise ValueError(f"ungueltiger Agent-Name: {agent!r}")
        path = os.path.realpath(os.path.join(self.queue_dir, f"{agent}.jsonl"))
        base = os.path.realpath(self.queue_dir)
        if not path.startswith(base + os.sep):
            raise ValueError(f"Queue-Pfad ausserhalb von {base}: {path}")
        return path

    def save_offline(self, agent: str, msg: dict) -> bool:
        """Nachricht zwischenspeichern. False, wenn das Limit erreicht ist."""
        path = self.queue_path(agent)
        try:
            st = os.stat(path)
            if st.st_size >= MAX_QUEUE_BYTES:
                log.warning("⛔ Queue von %s ist voll (%d B) — verworfen", agent, st.st_size)
                return False
            with open(path) as f:
                if sum(1 for _ in f) >= MAX_QUEUE_MSGS:
                    log.warning("⛔ Queue von %s hat %d Nachrichten — verworfen",
                                agent, MAX_QUEUE_MSGS)
                    return False
        except FileNotFoundError:
            pass
        with open(path, "a") as f:
            f.write(json.dumps({"ts": time.time(), "msg": msg}) + "\n")
        return True

    def load_offline(self, agent: str) -> list:
        path = self.queue_path(agent)
        if not os.path.exists(path):
            return []
        cutoff = time.time() - QUEUE_TTL
        msgs = []
        with open(path) as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("ts", 0) < cutoff:
                    continue          # abgelaufen (Audit-Befund D1)
                msgs.append(rec["msg"])
        os.remove(path)
        return msgs

    # ── Zustellung ──
    async def deliver(self, agent: str, msg: dict):
        targets = self.clients.get(agent, set())
        if targets:
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

    def rate_ok(self, agent: str) -> bool:
        now = time.time()
        hits = [t for t in self.rate.get(agent, []) if now - t < RATE_WINDOW]
        if len(hits) >= RATE_MSGS:
            self.rate[agent] = hits
            return False
        hits.append(now)
        self.rate[agent] = hits
        return True

    async def broadcast_presence(self, agent: str, status: str):
        # Ein Client, der im Sekundentakt neu verbindet, erzeugte bisher
        # quadratischen Fanout im Event-Loop.
        now = time.time()
        if now - self.last_presence.get(agent, 0.0) < PRESENCE_MIN_GAP:
            return
        self.last_presence[agent] = now
        for other, conns in list(self.clients.items()):
            if other == agent:
                continue
            for c in list(conns):
                try:
                    await c.send(json.dumps(
                        {"type": "presence", "agent": agent, "status": status}))
                except Exception:
                    pass

    # ── Verbindungs-Handler ──
    async def handle(self, ws):
        agent = None
        peer = "?"
        try:
            try:
                peer = ws.remote_address[0] if ws.remote_address else "?"
            except Exception:
                peer = "?"
            if self.conn_per_ip.get(peer, 0) >= MAX_CONN_PER_IP:
                log.warning("⛔ %s: zu viele gleichzeitige Verbindungen", peer)
                return
            self.conn_per_ip[peer] = self.conn_per_ip.get(peer, 0) + 1
            try:
                agent = await asyncio.wait_for(self.do_auth(ws), timeout=AUTH_TIMEOUT)
            except asyncio.TimeoutError:
                log.info("⛔ Auth-Timeout — Verbindung geschlossen")
                return
            if not agent:
                return

            if len(self.clients.get(agent, ())) >= MAX_CONN_PER_AGENT:
                log.warning("⛔ %s: Verbindungsgrenze pro Agent erreicht", agent)
                await ws.send(json.dumps({"type": "error", "error": "too_many_connections"}))
                return

            self.clients.setdefault(agent, set()).add(ws)
            log.info("🔗 %s verbunden (%d online)", agent, len(self.clients))
            await ws.send(json.dumps({"type": "auth_ok", "agent": agent}))
            for m in self.load_offline(agent):
                await ws.send(json.dumps(m))
            await self.broadcast_presence(agent, "online")

            async for raw in ws:
                try:
                    data = json.loads(raw)
                except Exception:
                    continue
                mtype = data.get("type")

                if mtype == "msg":
                    to = data.get("to", "")
                    blob = data.get("blob", "")
                    if not to or not blob:
                        continue
                    if not valid_agent(to) or not isinstance(blob, str):
                        log.warning("⛔ %s: ungueltiges Ziel abgelehnt (%r)", agent, to)
                        await ws.send(json.dumps(
                            {"type": "error", "error": "invalid_recipient"}))
                        continue
                    if not self.rate_ok(agent):
                        log.warning("⛔ %s: Rate-Limit erreicht", agent)
                        await ws.send(json.dumps({"type": "error", "error": "rate_limited"}))
                        continue
                    log.info("📨 %s → %s (%d B)", agent, to, len(blob))
                    await self.deliver(to, {"type": "msg", "from": agent,
                                            "blob": blob, "ts": time.time()})

                elif mtype == "ping":
                    await ws.send(json.dumps({"type": "pong"}))

        except websockets.exceptions.ConnectionClosed:
            pass
        except Exception as e:
            log.warning("⚠️  %s: %s", agent or "?", e)
        finally:
            if peer in self.conn_per_ip:
                self.conn_per_ip[peer] -= 1
                if self.conn_per_ip[peer] <= 0:
                    del self.conn_per_ip[peer]
            if agent and agent in self.clients:
                self.clients[agent].discard(ws)
                if not self.clients[agent]:
                    del self.clients[agent]
                    log.info("🔌 %s getrennt (%d online)", agent, len(self.clients))
                    await self.broadcast_presence(agent, "offline")


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8766)
    # SECURITY (Audit-Befund #9): Default ist localhost. Die Doku verspricht
    # "nur über Tailscale erreichbar" — dann gehört hier auch die Tailscale-IP
    # hin und nicht 0.0.0.0.
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--keys-dir",
                    default=os.environ.get("AGENT_MESH_KEYS_DIR",
                                           "/root/.agent-mesh/memories/vault/keys"))
    ap.add_argument("--queue-dir", default="/var/lib/agent-mesh-relay")
    ap.add_argument("--age-bin", default=os.environ.get("AGE_BIN", "age"))
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO,
                        format="[%(asctime)s] %(message)s", datefmt="%H:%M:%S")

    age_bin = shutil.which(args.age_bin) or args.age_bin
    if not shutil.which(args.age_bin):
        print(f"❌ age-Binary '{args.age_bin}' nicht gefunden — "
              f"ohne age ist keine Authentifizierung möglich.", file=sys.stderr)
        sys.exit(1)
    if not os.path.isdir(args.keys_dir):
        print(f"❌ Key-Registry '{args.keys_dir}' fehlt — der Relay braucht "
              f"Lesezugriff auf vault/keys/ (agent-mesh sync ausführen).",
              file=sys.stderr)
        sys.exit(1)

    n_keys = len([f for f in os.listdir(args.keys_dir) if f.endswith(".age.pub")])
    relay = Relay(args.keys_dir, args.queue_dir, age_bin)
    log.info("🚀 Agent-Mesh-Relay auf ws://%s:%d (%d Agent-Keys registriert)",
             args.host, args.port, n_keys)
    async with websockets.serve(relay.handle, args.host, args.port, max_size=MAX_FRAME):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
