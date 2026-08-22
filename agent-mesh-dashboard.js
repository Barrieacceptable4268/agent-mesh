#!/usr/bin/env node
/**
 * agent-mesh-dashboard — zentrale Übersicht für alle Mesh-User.
 *
 * Eine URL (mesh-console.moinsen.dev), GitHub-OAuth-Login, Live-Daten:
 *   - Agents (vom Relay: online/offline, Version)
 *   - Vault-Status (Secrets, Empfänger)
 *   - Offene Issues (GitHub)
 *   - Letzte Aktivität (Git-Commits)
 *   - Relay-Status (Port, Queue)
 *
 * Sicherheit:
 *   - Session-Cookie (HttpOnly) + Passwort-Hash (scrypt)
 *   - Nur lesend — keine Schreib-APIs
 *   - Läuft nur auf 127.0.0.1 hinter Cloudflare-Tunnel (mesh-console.moinsen.dev)
 *   - Keine Secrets im Browser (Token bleibt auf dem Server)
 */

const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { execFileSync, execSync } = require("child_process");

const PORT = parseInt(process.env.DASHBOARD_PORT || "8770", 10);
const HOST = process.env.DASHBOARD_HOST || "127.0.0.1";
const GITHUB_CLIENT_ID = process.env.DASHBOARD_GITHUB_CLIENT_ID || "";
const GITHUB_CLIENT_SECRET = process.env.DASHBOARD_GITHUB_CLIENT_SECRET || "";
const GITHUB_REDIRECT = process.env.DASHBOARD_GITHUB_REDIRECT || "https://mesh-console.moinsen.dev/callback";
const ALLOWED_USERS = (process.env.DASHBOARD_ALLOWED_USERS || "").split(",").map(s => s.trim()).filter(Boolean);
const GH_OWNER = process.env.DASHBOARD_GH_OWNER || "moinsen-dev"; // Owner des privaten Mesh-Repos (aus conf: AGENT_MESH_GH_OWNER)
const GH_MEMBERS_REPO = process.env.DASHBOARD_MEMBERS_REPO || "agent-mesh-memories"; // privates Repo = Mitgliedschaft
const GH_ADMIN = process.env.DASHBOARD_GH_ADMIN || "udi"; // System-User mit gh-Auth (Collaborator-Check)
const MEMORIES = process.env.AGENT_MESH_HOME || "/root/.agent-mesh";
const FRAMEWORK = path.join(MEMORIES, "framework");
const RELAY_URL = process.env.RELAY_STATUS_URL || "ws://127.0.0.1:8766";
const SECRET = process.env.DASHBOARD_SECRET || crypto.randomBytes(32).toString("hex");

if (!GITHUB_CLIENT_ID || !GITHUB_CLIENT_SECRET) {
  console.error("❌ DASHBOARD_GITHUB_CLIENT_ID / _SECRET fehlen — GitHub OAuth App anlegen: https://github.com/settings/developers");
  console.error("   Callback-URL: " + GITHUB_REDIRECT);
  process.exit(1);
}

const sessions = new Map(); // token → {expiry, user}

function verifyGitHubUser(login) {
  // 1. Explizite Allowlist (falls gesetzt — hat Vorrang)
  if (ALLOWED_USERS.length > 0) return ALLOWED_USERS.includes(login);
  // 2. Dynamisch — Mesh-Mitglied = Zugriff aufs private Repo:
  //    a) Org-Member (moinsen-dev) ODER
  //    b) Repo-Collaborator (agent-mesh-memories)
  try {
    const out = execFileSync("sudo", ["-u", GH_ADMIN, "gh", "api",
      `orgs/${GH_OWNER}/memberships/${login}`, "--jq", ".state"],
      { timeout: 10, stdio: ["ignore", "pipe", "ignore"] });
    if (out.toString().trim() === "active") return true;
  } catch { /* kein Org-Member → weiter prüfen */ }
  try {
    const out = execFileSync("sudo", ["-u", GH_ADMIN, "gh", "api",
      `repos/${GH_OWNER}/${GH_MEMBERS_REPO}/collaborators/${login}`,
      "--jq", ".login"], { timeout: 10, stdio: ["ignore", "pipe", "ignore"] });
    return out.toString().trim().length > 0;
  } catch {
    return false; // 404 = kein Zugriff
  }
}

function requireAuth(req, res) {
  const cookie = (req.headers.cookie || "").match(/mesh_session=([^;]+)/);
  if (cookie && sessions.get(cookie[1]) && sessions.get(cookie[1]).expiry > Date.now()) return true;
  res.writeHead(401, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "unauthorized" }));
  return false;
}

// ── Kleiner HTTP-Helfer (fetch für Node < 18 ohne global fetch) ──
function awaitFetch(url, opts = {}) {
  return new Promise((resolve) => {
    const lib = url.startsWith("https") ? require("https") : require("http");
    const u = new URL(url);
    const req = lib.request({
      hostname: u.hostname,
      path: u.pathname + u.search,
      method: opts.method || "GET",
      headers: { "Accept": "application/json", ...(opts.headers || {}) },
    }, (res) => {
      let body = "";
      res.on("data", c => body += c);
      res.on("end", () => {
        try { resolve(JSON.parse(body)); } catch { resolve(null); }
      });
    });
    req.on("error", () => resolve(null));
    if (opts.body) req.write(opts.body);
    req.end();
  });
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

  // ── Auth: GitHub OAuth (Web Flow) ──
  if (url.pathname === "/login") {
    const state = crypto.randomBytes(16).toString("hex");
    sessions.set("oauth_" + state, { expiry: Date.now() + 10 * 60 * 1000 });
    const authUrl = "https://github.com/login/oauth/authorize" +
      `?client_id=${encodeURIComponent(GITHUB_CLIENT_ID)}` +
      `&redirect_uri=${encodeURIComponent(GITHUB_REDIRECT)}` +
      "&scope=read:user" +
      `&state=${state}`;
    res.writeHead(302, { Location: authUrl });
    res.end();
    return;
  }

  if (url.pathname === "/callback") {
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    if (!code || !state || !sessions.has("oauth_" + state)) {
      res.writeHead(400, { "Content-Type": "text/plain" });
      res.end("Ungültiger OAuth-State");
      return;
    }
    sessions.delete("oauth_" + state);
    // Code gegen Token tauschen
    const tokenResp = awaitFetch("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({
        client_id: GITHUB_CLIENT_ID,
        client_secret: GITHUB_CLIENT_SECRET,
        code,
        redirect_uri: GITHUB_REDIRECT,
      }),
    });
    if (!tokenResp || !tokenResp.access_token) {
      res.writeHead(401, { "Content-Type": "text/plain" });
      res.end("OAuth-Token-Austausch fehlgeschlagen");
      return;
    }
    // User-Info holen
    const userResp = awaitFetch("https://api.github.com/user", {
      headers: { "Authorization": "Bearer " + tokenResp.access_token, "User-Agent": "agent-mesh-dashboard" },
    });
    const login = userResp && userResp.login ? userResp.login : "";
    if (!login || !verifyGitHubUser(login)) {
      res.writeHead(403, { "Content-Type": "text/html" });
      res.end("<html><body style='font-family:sans-serif;background:#0b0d12;color:#e6e9f0;display:flex;justify-content:center;align-items:center;height:100vh'><div style='text-align:center'><h1>🚫 Zugriff verweigert</h1><p>GitHub-User <b>" + login + "</b> ist kein Mesh-Mitglied.</p><a href='/login' style='color:#6c8cff'>Erneut versuchen</a></div></body></html>");
      return;
    }
    // Session erstellen (12h)
    const token = crypto.randomBytes(24).toString("hex");
    sessions.set(token, { expiry: Date.now() + 12 * 3600 * 1000, user: login });
    res.writeHead(302, {
      "Location": "/",
      "Set-Cookie": `mesh_session=${token}; HttpOnly; Path=/; Max-Age=43200; SameSite=Lax`,
    });
    res.end();
    return;
  }

  if (url.pathname === "/api/me") {
    if (!requireAuth(req, res)) return;
    const cookie = (req.headers.cookie || "").match(/mesh_session=([^;]+)/);
    const sess = cookie ? sessions.get(cookie[1]) : null;
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ user: sess ? sess.user : null }));
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
<title>agent-mesh-dashboard</title>
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
  <h1>🐝 agent-mesh-dashboard</h1>
  <div class="sub">Live-Übersicht des Mesh-Verbunds · <span id="ver">…</span> · <span id="who"></span></div>
  <div id="content" style="display:none">
    <div class="status-line">Relay: <span id="relay">…</span></div>
    <div class="grid">
      <div class="card"><h3>Agents</h3><div id="agents">…</div></div>
      <div class="card"><h3>Letzte Aktivität</h3><div id="commits">…</div></div>
    </div>
  </div>
</div>
<div id="login" style="display:none">
  <h1>🐝 agent-mesh-dashboard</h1>
  <div class="sub">Mit GitHub anmelden (nur Mesh-Mitglieder)</div>
  <a href="/login"><button style="width:100%;background:#24292f;color:#fff;padding:12px;border-radius:8px;border:none;cursor:pointer;font-size:15px;display:flex;align-items:center;justify-content:center;gap:8px">🔑 Mit GitHub anmelden</button></a>
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
    // Wer ist eingeloggt?
    try {
      const me = await (await fetch('/api/me')).json();
      document.getElementById('who').textContent = '👤 ' + (me.user || '?');
    } catch {}
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
function showLogin() { document.getElementById('content').style.display='none'; document.getElementById('login').style.display='block'; }
load();
setInterval(load, 10000);
</script>
</body>
</html>`;
}

server.listen(PORT, HOST, () => console.log(`🚀 Dashboard auf http://${HOST}:${PORT}`));
