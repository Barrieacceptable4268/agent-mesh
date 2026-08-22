#!/usr/bin/env python3
"""agent-mesh-webhook — Echtzeit-Trigger für das Agent-Mesh.

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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get("AGENT_MESH_WEBHOOK_SECRET", "")
AGENT_MESH_BIN = os.environ.get("AGENT_MESH_BIN", "/usr/local/bin/agent-mesh")
EXPECTED_REPO = "moinsen-dev/agent-mesh-memories"

# Audit-Befund D6: Der Body wurde ungeprueft und VOR der Signaturpruefung in
# den Speicher gelesen. GitHub-Push-Payloads liegen weit unter 1 MB.
MAX_BODY = 1 * 1024 * 1024


def verify_signature(payload: bytes, signature: str) -> bool:
    if not SECRET or not signature:
        return False
    expected = "sha256=" + hmac.new(
        SECRET.encode(), payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


class Handler(BaseHTTPRequestHandler):
    # Kein HTTP/1.1: das verlangt Content-Length auf jeder Antwort, sonst
    # wartet der Client bei Keep-Alive auf ein Body-Ende, das nie kommt.
    # HTTP/1.0 schliesst nach der Antwort — fuer einen Webhook genau richtig.
    timeout = 15        # haengende Verbindungen nicht ewig halten

    def do_POST(self):
        if self.path != "/hook":
            self.send_response(404)
            self.end_headers()
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self.send_response(400)
            self.end_headers()
            return
        if length < 0 or length > MAX_BODY:
            self.send_response(413)
            self.end_headers()
            return
        payload = self.rfile.read(length)
        if len(payload) != length:          # abgebrochene Uebertragung
            self.send_response(400)
            self.end_headers()
            return
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
        # Log-Handle schliessen statt pro Request einen Deskriptor zu verlieren.
        # Faellt der Start fehl (z.B. AGENT_MESH_BIN fehlt nach einem
        # missglueckten Update), muss das eine saubere 500 geben — sonst stirbt
        # der Handler und der Aufrufer bekommt gar keine Antwort.
        try:
            with open("/var/log/agent-mesh-webhook.log", "a") as logf:
                subprocess.Popen([AGENT_MESH_BIN, "sync"],
                                 stdout=logf, stderr=subprocess.STDOUT)
        except OSError as e:
            sys.stderr.write(f"[agent-mesh-webhook] sync konnte nicht starten: {e}\n")
            self.send_response(500)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok","triggered":"sync"}')

    def do_GET(self):
        # Healthcheck ohne Secret (nur Status, keine Aktion)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"agent-mesh-webhook running"}')

    def log_message(self, fmt, *args):
        sys.stderr.write("[agent-mesh-webhook] %s\n" % (fmt % args))


def main():
    port = int(os.environ.get("AGENT_MESH_WEBHOOK_PORT", "8765"))
    if not SECRET:
        print("❌ AGENT_MESH_WEBHOOK_SECRET nicht gesetzt", file=sys.stderr)
        sys.exit(1)
    # Threading: eine langsame Verbindung darf nicht alle weiteren blockieren
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    print(f"✅ agent-mesh-webhook auf 127.0.0.1:{port} (Secret: {'gesetzt' if SECRET else 'FEHLT'})")
    server.serve_forever()


if __name__ == "__main__":
    main()
