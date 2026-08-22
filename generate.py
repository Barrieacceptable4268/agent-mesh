#!/usr/bin/env python3
"""
generate.py — baut README.md + index.html aus den Single-Source-Dateien.

Quellen (im Framework-Repo):
  docs/INSTALL.md    — Installations-Anleitung (die Webpage-Sektion)
  docs/COMMANDS.md   — Kommando-Referenz (README-Tabelle)

Ausgaben:
  README.md          — im Framework-Repo (Install-Sektion aus INSTALL.md)
  site/index.html    — Landingpage (nach moinsen.dev-Repo kopieren)

Damit sind Webpage und README IMMER synchron: eine Quelle, zwei Ausgaben.
Aufruf: python3 generate.py
"""
import html
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DOCS = ROOT / "docs"
README = ROOT / "README.md"
SITE = ROOT / "site"
INDEX = SITE / "index.html"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def md_to_html(md: str) -> str:
    """Mini-Markdown → HTML (Überschriften, Listen, Code-Blöcke, Tabellen, Bold)."""
    lines = md.splitlines()
    out: list[str] = []
    i = 0
    in_code = False
    in_list = False
    in_table = False

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    while i < len(lines):
        line = lines[i]
        # Code-Block
        if line.strip().startswith("```"):
            if in_code:
                out.append("</code></pre>")
                in_code = False
            else:
                out.append('<pre class="code"><code>')
                in_code = True
            i += 1
            continue
        if in_code:
            out.append(html.escape(line))
            i += 1
            continue
        # Überschriften
        m = re.match(r"^(#{1,3})\s+(.*)", line)
        if m:
            close_list()
            level = len(m.group(1))
            out.append(f"<h{level+2}>{inline(m.group(2))}</h{level+2}>")
            i += 1
            continue
        # Liste
        m = re.match(r"^\s*[-*]\s+(.*)", line)
        if m:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(m.group(1))}</li>")
            i += 1
            continue
        # Tabelle (einfach: | a | b |)
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|[\s\-:|]+\|\s*$", lines[i+1]):
            close_list()
            if not in_table:
                out.append('<div class="table-wrap"><table>')
                in_table = True
            cells = [c.strip() for c in line.strip("|").split("|")]
            if in_table and "<thead>" not in "".join(out[-3:]):
                out.append("<thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in cells) + "</tr></thead><tbody>")
            else:
                out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in cells) + "</tr>")
            i += 2
            continue
        if in_table and not line.startswith("|"):
            out.append("</tbody></table></div>")
            in_table = False
        # Leerzeile
        if not line.strip():
            close_list()
            if in_table:
                out.append("</tbody></table></div>")
                in_table = False
            out.append("")
            i += 1
            continue
        # Absatz
        close_list()
        out.append(f"<p>{inline(line)}</p>")
        i += 1
    close_list()
    if in_table:
        out.append("</tbody></table></div>")
    return "\n".join(out)


def inline(text: str) -> str:
    text = html.escape(text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    return text


def build_readme(install_md: str, commands_md: str) -> str:
    install_section = re.sub(r"^# .*\n\n", "", install_md, count=1)  # Titel raus
    install_section = install_section.replace(
        "[COMMANDS.md](COMMANDS.md)", "[docs/COMMANDS.md](docs/COMMANDS.md)"
    ).replace(
        "[docs/ONBOARDING.md](docs/ONBOARDING.md)", "[docs/ONBOARDING.md](docs/ONBOARDING.md)"
    )
    commands_section = re.sub(r"^# .*\n\n", "", commands_md, count=1)
    return f"""# Agent-Mesh

**Connect your AI agents. Make them smarter together.**

Agent-Mesh links multiple [Hermes agents](https://hermes-agent.nousresearch.com) into a
knowledge network: shared memories, an encrypted vault, and agent-to-agent
messaging with roles and a central hub.

- **Public repo** (`agent-mesh`): this framework — anyone can use it.
- **Private repo** (`agent-mesh-memories`): the data (memories/skills/vault).
  Personal data never lives in the public repo.

---

## 🚀 Install (one command — works for humans AND agents)

{install_section}

## Commands

{commands_section}

## Privacy

- **Public**: framework code only. No personal data.
- **Private**: memories/skills/insights/vault. Never make it public.
- Hermes profile export redacts secrets automatically; `agent-mesh sync`
  exports agent-created skills only.

## License

MIT
"""


def build_site(install_md: str) -> str:
    body = md_to_html(install_md)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Agent-Mesh — connect your AI agents</title>
  <meta name="description" content="Agent-Mesh — open-source framework that connects multiple AI agents into a knowledge network: shared memories, encrypted vault, agent-to-agent messaging. One-command install.">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
  <style>
    :root {{
      --bg: #0b0d12; --bg-soft: #12151d; --border: #232836;
      --text: #e6e9f0; --muted: #8b93a7; --accent: #6c8cff; --accent-2: #48d597;
      --mono: 'JetBrains Mono', monospace;
    }}
    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
    body {{ background: var(--bg); color: var(--text); font-family: 'Inter', -apple-system, sans-serif; line-height: 1.6; min-height: 100vh; display: flex; flex-direction: column; }}
    .container {{ max-width: 760px; margin: 0 auto; padding: 0 24px; width: 100%; }}
    header {{ padding: 48px 0 24px; border-bottom: 1px solid var(--border); }}
    .logo {{ font-family: var(--mono); font-weight: 600; color: var(--accent); font-size: 15px; }}
    .logo span {{ color: var(--muted); }}
    main {{ flex: 1; padding: 40px 0 32px; }}
    h1 {{ font-size: clamp(28px, 5vw, 40px); font-weight: 700; letter-spacing: -0.02em; line-height: 1.12; margin-bottom: 12px; }}
    h2 {{ font-size: 20px; font-weight: 600; margin: 36px 0 14px; color: var(--accent); }}
    h3 {{ font-size: 16px; font-weight: 600; margin: 24px 0 10px; }}
    h4 {{ font-size: 14px; font-weight: 600; margin: 18px 0 8px; color: var(--muted); }}
    p {{ color: var(--text); margin-bottom: 12px; }}
    ul {{ margin: 0 0 16px 20px; color: var(--muted); }}
    li {{ margin-bottom: 6px; }}
    a {{ color: var(--accent); }}
    code {{ font-family: var(--mono); font-size: 13px; background: var(--bg-soft); padding: 1px 6px; border-radius: 4px; }}
    pre.code {{ background: var(--bg-soft); border: 1px solid var(--border); border-radius: 10px; padding: 16px 20px; font-family: var(--mono); font-size: 13.5px; color: var(--accent-2); overflow-x: auto; margin: 8px 0 20px; }}
    pre.code code {{ background: none; padding: 0; }}
    .table-wrap {{ overflow-x: auto; margin: 8px 0 20px; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
    th {{ text-align: left; color: var(--accent); font-weight: 600; padding: 8px 12px; border-bottom: 2px solid var(--border); }}
    td {{ padding: 8px 12px; border-bottom: 1px solid var(--border); color: var(--muted); }}
    strong {{ color: var(--text); }}
    .links {{ display: flex; gap: 24px; flex-wrap: wrap; margin-top: 32px; }}
    .links a {{ color: var(--muted); text-decoration: none; font-family: var(--mono); font-size: 14px; transition: color 0.2s; }}
    .links a:hover {{ color: var(--accent); }}
    footer {{ border-top: 1px solid var(--border); padding: 24px 0 40px; color: var(--muted); font-size: 13px; font-family: var(--mono); }}
    .terminal-line {{ color: var(--accent-2); }}
  </style>
</head>
<body>
  <header>
    <div class="container">
      <div class="logo">agent-mesh<span>.moinsen.dev</span></div>
    </div>
  </header>
  <main>
    <div class="container">
      {body}
      <div class="links">
        <a href="https://github.com/moinsen-dev/agent-mesh" target="_blank" rel="noopener">→ github.com/moinsen-dev/agent-mesh</a>
        <a href="https://github.com/moinsen-dev" target="_blank" rel="noopener">→ more from moinsen-dev</a>
      </div>
    </div>
  </main>
  <footer>
    <div class="container">
      <div class="terminal-line">$ agent-mesh status · ax41 [hub] · macbook [worker] · all connected</div>
      <div>© <span id="year"></span> moinsen.dev · Hamburg, Germany · Open source · MIT</div>
    </div>
  </footer>
  <script>document.getElementById('year').textContent = new Date().getFullYear();</script>
</body>
</html>
"""


def main():
    install_md = read(DOCS / "INSTALL.md")
    commands_md = read(DOCS / "COMMANDS.md")

    README.write_text(build_readme(install_md, commands_md), encoding="utf-8")
    SITE.mkdir(exist_ok=True)
    INDEX.write_text(build_site(install_md), encoding="utf-8")

    print(f"✅ README.md  → {README} ({len(README.read_text())} bytes)")
    print(f"✅ index.html → {INDEX} ({len(INDEX.read_text())} bytes)")
    print("ℹ️  Kopiere site/index.html nach moinsen.dev-Repo (oder GitHub Action macht es)")


if __name__ == "__main__":
    main()
