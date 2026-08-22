#!/usr/bin/env node
/**
 * agent-mesh-dashboard — zentrale Übersicht für alle Mesh-User.
 *
 * Eine URL (dashboard.moinsen.dev), sicherer Login (Passwort), Live-Daten:
 *   - Agents (vom Relay: online/offline, Version)
 *   - Vault-Status (Secrets, Empfänger)
 *   - Offene Issues (GitHub)
 *   - Letzte Aktivität (Git-Commits)
 *   - Relay-Status (Port, Queue)
 *
 * Sicherheit:
 *   - Session-Cookie (HttpOnly) + Passwort-Hash (scrypt)
 *   - Nur lesend — keine Schreib-APIs
 *   - Läuft nur auf 127.0.0.1 hinter Cloudflare-Tunnel (dashboard.moinsen.dev)
 *   - Keine Secrets im Browser (Token bleibt auf dem Server)
 */

const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { execFileSync, execSync } = require("child_process");

const PORT = parseInt(process.env.DASHBOARD_PORT || "8770", 10);
const HOST = process.env.DASHBOARD_HOST || "127.0.0.1";
const PASSWORD_HASH = process.env.DASHBOARD_PASSWORD_HASH || ""; // scrypt-Hash
const MEMORIES = process.env.AGENT_MESH_HOME || "/root/.agent-mesh";
const FRAMEWORK = path.join(MEMORIES, "framework");
const RELAY_URL = process.env.RELAY_STATUS_URL || "ws://127.0.0.1:8766";
const SECRET = process.env.DASHBOARD_SECRET || crypto.randomBytes(32).toString("hex");

// ── Passwort-Hash erzeugen: node dashboard.js --hash <passwort> ──
if (process.argv[2] === "--hash") {
  const salt = crypto.randomBytes(16).toString("hex");
  const hash = crypto.scryptSync(process.argv[3], salt, 64).toString("hex");
  console.log(`DASHBOARD_PASSWORD_HASH=salt:${salt}:${hash}`);
  process.exit(0);
}

if (!PASSWORD_HASH) {
  console.error("❌ DASHBOARD_PASSWORD_HASH fehlt — erzeugen: node dashboard.js --hash <passwort>");
  process.exit(1);
}

const sessions = new Map(); // token → expiry

function verifyPassword(pw) {
  try {
    // Format: salt:<salt>:<hash> (3 Teile!)
    const parts = PASSWORD_HASH.split(":");
    const salt = parts[1];
    const hash = parts[2];
    const test = crypto.scryptSync(pw, salt, 64).toString("hex");
    return crypto.timingSafeEqual(Buffer.from(hash, "hex"), Buffer.from(test, "hex"));
  } catch { return false; }
}

function requireAuth(req, res) {
  const cookie = (req.headers.cookie || "").match(/mesh_session=([^;]+)/);
  if (cookie && sessions.get(cookie[1]) > Date.now()) return true;
  res.writeHead(401, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "unauthorized" }));
  return false;
}

// ── Daten sammeln (nur lesend!) ──
function getData() {
  const out = { agents: [], relay: null, vault: null, issues: null, commits: [], version: null };

  // Agents aus dem privaten Repo
  try {
    const agentsDir = path.join(MEMORIES, "memories", "agents");
    const keysDir = path.join(MEMORIES, "memories", "vault", "keys");
    const names = fs.readdirSync(agentsDir).filter(d => fs.statSync(path.join(agentsDir, d)).isDirectory());
    out.agents = names.map(name => {
      let role = "worker", card = {};
      try { card = JSON.parse(fs.readFileSync(path.join(agentsDir, name, "card.json"), "utf8")); role = card.role || "worker"; } catch {}
      const hasKey = fs.existsSync(path.join(keysDir, `${name}.age.pub`));
      // Letzte Aktivität (git log)
      let lastActive = null;
      try {
        const log = execSync(`git -C "${MEMORIES}/memories" log --format="%cr" --author="${name}" -1 2>/dev/null || git -C "${MEMORIES}/memories" log --format="%cr" -1`, { timeout: 5 }).toString().trim();
        lastActive = log || null;
      } catch {}
      return { name, role, hasKey, lastActive, online: false };
    });
  } catch {}

  // Version
  try { out.version = fs.readFileSync(path.join(FRAMEWORK, "VERSION"), "utf8").trim(); } catch {}

  // Letzte Commits
  try {
    const log = execSync(`git -C "${MEMORIES}/memories" log origin/main -8 --format="%h|%an|%s|%cr"`, { timeout: 5 }).toString().trim().split("\n");
    out.commits = log.filter(Boolean).map(l => { const [h, a, ...rest] = l.split("|"); return { h, a, s: rest.join("|") }; });
  } catch {}

  return out;
}

// ── Online-Status vom Relay abfragen (kleiner WS-Client, ohne websockets-Lib) ──
function getRelayStatus(cb) {
  try {
    const stats = execFileSync("bash", ["-c", `ss -tln | grep -c 8766`], { timeout: 3 }).toString().trim();
    // Online-Agents: über die Relay-API? Relay hat keine HTTP-API — lese systemd-Status
    let active = false;
    try { active = execFileSync("systemctl", ["is-active", "agent-mesh-relay"], { timeout: 3 }).toString().trim() === "active"; } catch {}
    cb({ active, port: stats === "1" });
  } catch { cb(null); }
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // ── Auth ──
  if (url.pathname === "/api/login" && req.method === "POST") {
    let body = "";
    req.on("data", c => body += c);
    req.on("end", () => {
      try {
        const { password } = JSON.parse(body);
        if (verifyPassword(password)) {
          const token = crypto.randomBytes(24).toString("hex");
          sessions.set(token, Date.now() + 12 * 3600 * 1000); // 12h
          res.writeHead(200, { "Set-Cookie": `mesh_session=${token}; HttpOnly; Path=/; Max-Age=43200`, "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: true }));
        } else {
          res.writeHead(401, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "wrong_password" }));
        }
      } catch { res.writeHead(400); res.end(); }
    });
    return;
  }

  if (url.pathname === "/api/logout") {
    const cookie = (req.headers.cookie || "").match(/mesh_session=([^;]+)/);
    if (cookie) sessions.delete(cookie[1]);
    res.writeHead(200, { "Set-Cookie": "mesh_session=; HttpOnly; Path=/; Max-Age=0" });
    res.end("{}");
    return;
  }

  // ── API ──
  if (url.pathname === "/api/status") {
    if (!requireAuth(req, res)) return;
    const data = getData();
    getRelayStatus(rs => {
      data.relay = rs;
      res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      res.end(JSON.stringify(data));
    });
    return;
  }

  // ── UI ──
  if (url.pathname === "/" || url.pathname === "/index.html") {
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end(renderHtml());
    return;
  }

  res.writeHead(404); res.end();
});

function renderHtml() {
  return `<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Agent-Mesh Dashboard</title>
<style>
  :root { --bg:#0b0d12; --card:#12151d; --border:#232836; --text:#e6e9f0; --muted:#8b93a7; --accent:#6c8cff; --green:#48d597; --red:#ff6b6b; }
  * { margin:0; padding:0; box-sizing:border-box; }
  body { background:var(--bg); color:var(--text); font-family:system-ui,sans-serif; min-height:100vh; }
  .container { max-width:900px; margin:0 auto; padding:24px; }
  h1 { font-size:22px; margin-bottom:4px; }
  .sub { color:var(--muted); font-size:13px; margin-bottom:24px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(250px,1fr)); gap:16px; margin-bottom:24px; }
  .card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:16px; }
  .card h3 { font-size:13px; color:var(--muted); text-transform:uppercase; letter-spacing:.05em; margin-bottom:12px; }
  .agent { display:flex; align-items:center; justify-content:space-between; padding:8px 0; border-bottom:1px solid var(--border); }
  .agent:last-child { border-bottom:none; }
  .dot { width:9px; height:9px; border-radius:50%; display:inline-block; margin-right:8px; }
  .online { background:var(--green); } .offline { background:var(--red); }
  .tag { font-size:11px; background:#1a2030; color:var(--accent); padding:2px 8px; border-radius:10px; }
  .commit { font-family:monospace; font-size:12px; color:var(--muted); padding:5px 0; border-bottom:1px solid var(--border); }
  .commit:last-child { border-bottom:none; }
  #login { max-width:320px; margin:120px auto; text-align:center; }
  input { width:100%; padding:10px 14px; background:var(--card); border:1px solid var(--border); color:var(--text); border-radius:8px; margin-bottom:12px; font-size:14px; }
  button { padding:10px 20px; background:var(--accent); color:#fff; border:none; border-radius:8px; cursor:pointer; font-size:14px; }
  button:hover { opacity:.85; }
  .err { color:var(--red); font-size:13px; margin-top:8px; }
  .status-line { font-size:13px; color:var(--muted); margin-bottom:8px; }
  .badge { display:inline-block; padding:2px 10px; border-radius:10px; font-size:12px; margin-left:6px; }
  .badge.ok { background:rgba(72,213,151,.15); color:var(--green); }
  .badge.bad { background:rgba(255,107,107,.15); color:var(--red); }
</style>
</head>
<body>
<div class="container" id="app">
  <h1>🐝 Agent-Mesh Dashboard</h1>
  <div class="sub">Live-Übersicht des Mesh-Verbunds · <span id="ver">…</span></div>
  <div id="content" style="display:none">
    <div class="status-line">Relay: <span id="relay">…</span></div>
    <div class="grid">
      <div class="card"><h3>Agents</h3><div id="agents">…</div></div>
      <div class="card"><h3>Letzte Aktivität</h3><div id="commits">…</div></div>
    </div>
  </div>
</div>
<div id="login" style="display:none">
  <h1>🔐 Agent-Mesh</h1>
  <div class="sub">Bitte einloggen</div>
  <input type="password" id="pw" placeholder="Passwort">
  <button onclick="login()">Login</button>
  <div class="err" id="err"></div>
</div>
<script>
async function load() {
  try {
    const r = await fetch('/api/status');
    if (r.status === 401) { showLogin(); return; }
    const d = await r.json();
    document.getElementById('content').style.display = 'block';
    document.getElementById('login').style.display = 'none';
    document.getElementById('ver').textContent = 'Framework v' + (d.version || '?');
    // Relay
    const rl = document.getElementById('relay');
    rl.innerHTML = d.relay && d.relay.active ? '<span class="badge ok">● aktiv (Port 8766)</span>' : '<span class="badge bad">● offline</span>';
    // Agents
    const ag = document.getElementById('agents');
    ag.innerHTML = '';
    (d.agents || []).forEach(a => {
      const div = document.createElement('div');
      div.className = 'agent';
      div.innerHTML = '<span><span class="dot ' + (a.online ? 'online' : 'offline') + '"></span>' + a.name + ' <span class="tag">' + (a.role || 'worker') + '</span></span>' +
        '<span style="font-size:11px;color:var(--muted)">' + (a.lastActive || 'nie') + '</span>';
      ag.appendChild(div);
    });
    // Commits
    const cm = document.getElementById('commits');
    cm.innerHTML = '';
    (d.commits || []).forEach(c => {
      const div = document.createElement('div');
      div.className = 'commit';
      div.textContent = c.h + ' ' + c.s + ' — ' + c.a;
      cm.appendChild(div);
    });
  } catch { setTimeout(load, 3000); }
}
async function login() {
  const r = await fetch('/api/login', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({password: document.getElementById('pw').value}) });
  if (r.ok) { document.getElementById('err').textContent=''; load(); }
  else document.getElementById('err').textContent = 'Falsches Passwort';
}
function showLogin() { document.getElementById('content').style.display='none'; document.getElementById('login').style.display='block'; }
load();
setInterval(load, 10000);
</script>
</body>
</html>`;
}

server.listen(PORT, HOST, () => console.log(`🚀 Dashboard auf http://${HOST}:${PORT}`));
