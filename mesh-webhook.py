#!/usr/bin/env python3
"""mesh-webhook — Echtzeit-Trigger für das Agent-Mesh.

Empfängt GitHub-Webhooks (Push auf agent-mesh-memories), verifiziert die
HMAC-Signatur (X-Hub-Signature-256) gegen ein Secret und stößt sofort
mesh sync + Inbox-Check an — keine Cron-Wartezeit mehr.

Safety First:
  - Laustcht nur auf 127.0.0.1 (Tunnel macht den Rest)
  - HMAC-SHA256-Signatur wird gegen WEBHOOK_SECRET geprüft
  - Nur POST, nur /hook, nur Push-Events des privaten Repos
"""
import hashlib
import hmac
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = os.environ.get("MESH_WEBHOOK_SECRET", "")
MESH_BIN = os.environ.get("MESH_BIN", "/usr/local/bin/mesh")
EXPECTED_REPO = "moinsen-dev/agent-mesh-memories"


def verify_signature(payload: bytes, signature: str) -> bool:
    if not SECRET or not signature:
        return False
    expected = "sha256=" + hmac.new(
        SECRET.encode(), payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/hook":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(length)
        signature = self.headers.get("X-Hub-Signature-256", "")

        if not verify_signature(payload, signature):
            self.send_response(401)
            self.end_headers()
            return

        # Event + Repo prüfen (nur Push auf das private Mesh-Repo)
        event = self.headers.get("X-GitHub-Event", "")
        try:
            body = json.loads(payload)
            repo = body.get("repository", {}).get("full_name", "")
        except json.JSONDecodeError:
            repo = ""
        if event != "push" or repo != EXPECTED_REPO:
            self.send_response(200)  # ok, aber ignorieren (kein Spam)
            self.end_headers()
            return

        # Sofortiger Sync + Inbox (asynchron, blockiert nicht den Webhook)
        subprocess.Popen(
            [MESH_BIN, "sync"],
            stdout=open("/var/log/mesh-webhook.log", "a"),
            stderr=subprocess.STDOUT,
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok","triggered":"sync"}')

    def do_GET(self):
        # Healthcheck ohne Secret (nur Status, keine Aktion)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"mesh-webhook running"}')

    def log_message(self, fmt, *args):
        sys.stderr.write("[mesh-webhook] %s\n" % (fmt % args))


def main():
    port = int(os.environ.get("MESH_WEBHOOK_PORT", "8765"))
    if not SECRET:
        print("❌ MESH_WEBHOOK_SECRET nicht gesetzt", file=sys.stderr)
        sys.exit(1)
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(f"✅ mesh-webhook auf 127.0.0.1:{port} (Secret: {'gesetzt' if SECRET else 'FEHLT'})")
    server.serve_forever()


if __name__ == "__main__":
    main()
