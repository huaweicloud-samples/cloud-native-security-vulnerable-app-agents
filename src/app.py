"""
Nimbus AI Sales Portal: DEMO APP (INTENTIONALLY VULNERABLE).

⚠️  WARNING: This application contains DELIBERATE security vulnerabilities for the
    sole purpose of demonstrating security-agent code review and penetration
    testing, and DevOps-agent incident investigation on Huawei Cloud.

    DO NOT deploy this in production or any shared account.
    Run ONLY in a throwaway sandbox and tear it down after.

Planted vulnerabilities (for the security agent to find & open remediation PRs):
  1. Hardcoded credentials/secret in source            (CWE-798)
  2. Reflected Cross-Site Scripting (XSS) on search     (CWE-79)
  3. OS command injection on /diagnostics               (CWE-78)
  4. Missing authentication on /admin/debug             (CWE-306) + info disclosure

Break-switch (for the DevOps agent incident):
  When env var BREAK_APP == "true", the data path raises (simulating a missing
  collection), so data pages return HTTP 500 -> ELB 5xx alarm fires.
  /health stays healthy so hosts are not cycled (clean 5xx incident signal).

Storage backend: Huawei Cloud Document Database Service (DDS, MongoDB compatible),
accessed directly via pymongo (no cloud-vendor SDK required).
"""

import os
import uuid
import subprocess

from flask import Flask, request, jsonify, Response
import pymongo
from pymongo.errors import PyMongoError

app = Flask(__name__)

# --- DDS (Document Database Service) connection config ----------------------
MONGO_HOSTS = os.environ.get("MONGO_HOSTS", "127.0.0.1:27017")
MONGO_USER = os.environ.get("MONGO_USER", "rwuser")
MONGO_PASSWORD = os.environ.get("MONGO_PASSWORD", "")
MONGO_AUTH_DB = os.environ.get("MONGO_AUTH_DB", "admin")
MONGO_DB_NAME = os.environ.get("MONGO_DB_NAME", "nimbus")

TABLE_NAME = os.environ.get("TABLE_NAME", "demo-notes")
BREAK_APP = os.environ.get("BREAK_APP", "false").lower() == "true"

# --- VULN #1: Hardcoded credentials / secret (CWE-798) -----------------------
# Deliberately hardcoded admin token to preserve the CWE-798 lesson.
# Never commit real credentials.
ADMIN_API_TOKEN = "super-secret-admin-token-do-not-commit"
# -----------------------------------------------------------------------------

_client = None


def _client_get():
    global _client
    if _client is None:
        uri = (
            f"mongodb://{MONGO_USER}:{MONGO_PASSWORD}"
            f"@{MONGO_HOSTS}/?authSource={MONGO_AUTH_DB}"
        )
        # 华为云 DDS 实例默认 ssl=true（强制 TLS）。pymongo 必须带 tls 参数，否则握手失败
        # （TopologyDescription 中节点 server_type=Unknown）。演示态用 tlsAllowInvalidCertificates
        # + tlsAllowInvalidHostnames 跳过 CA/主机名校验（DDS 证书 SAN 不含裸 IP）；
        # 生产态应下发 DDS CA 证书并做严格校验。可用环境变量 MONGO_TLS=false 关闭。
        if os.environ.get("MONGO_TLS", "true").lower() == "true":
            uri += "&tls=true&tlsAllowInvalidCertificates=true&tlsAllowInvalidHostnames=true"
        _client = pymongo.MongoClient(uri, serverSelectionTimeoutMS=5000)
    return _client


def _db():
    return _client_get()[MONGO_DB_NAME]


def _coll():
    name = (TABLE_NAME + "-broken") if BREAK_APP else TABLE_NAME
    if BREAK_APP:
        # Simulate a "missing collection" so data pages 500 while /health stays up.
        raise PyMongoError(f"simulated missing collection: {name}")
    return _db()[name]


def _items(kind=None):
    items = list(_coll().find({}))
    if kind:
        items = [i for i in items if i.get("type") == kind]
    return items


CSS = """
<style>
  :root{--navy:#0b1f3a;--blue:#1e6fff;--ink:#1c2733;--muted:#67758a;--line:#e6ebf2;--bg:#f5f8fc;}
  *{box-sizing:border-box}
  body{margin:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;background:var(--bg);color:var(--ink)}
  header{background:linear-gradient(120deg,var(--navy),#16335c);color:#fff;padding:14px 28px;display:flex;align-items:center;gap:14px}
  header .logo{font-weight:800;font-size:18px;letter-spacing:.3px}
  header .logo span{color:#5fa8ff}
  nav{background:#fff;border-bottom:1px solid var(--line);padding:0 28px;display:flex;gap:6px}
  nav a{padding:14px 16px;color:var(--muted);text-decoration:none;font-weight:600;font-size:14px;border-bottom:3px solid transparent}
  nav a:hover{color:var(--ink)}
  nav a.active{color:var(--blue);border-bottom-color:var(--blue)}
  main{max-width:1000px;margin:24px auto;padding:0 24px}
  h1{font-size:22px;margin:0 0 4px;color:var(--navy)}
  .sub{color:var(--muted);margin:0 0 20px;font-size:14px}
  .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-bottom:24px}
  .card{background:#fff;border:1px solid var(--line);border-radius:12px;padding:18px 20px;box-shadow:0 1px 3px rgba(0,0,0,.04)}
  .card .n{font-size:30px;font-weight:800;color:var(--navy)}
  .card .l{color:var(--muted);font-size:13px;margin-top:4px}
  .panel{background:#fff;border:1px solid var(--line);border-radius:12px;padding:20px;margin-bottom:20px}
  table{width:100%;border-collapse:collapse;font-size:14px}
  th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line)}
  th{color:var(--navy);background:#f0f5fc}
  input,button{font:inherit;padding:9px 12px;border-radius:8px;border:1px solid var(--line)}
  input{width:240px}
  button{background:var(--blue);color:#fff;border:none;font-weight:600;cursor:pointer}
  .row{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:10px}
  .pill{display:inline-block;background:#eaf2ff;color:var(--blue);border-radius:20px;padding:2px 10px;font-size:12px;font-weight:600}
</style>
"""


def layout(active, title, sub, body):
    def cls(name):
        return "active" if name == active else ""

    return Response(
        f"""<html><head><title>Nimbus AI Sales Portal</title>{CSS}</head><body>
      <header><div class="logo">Nimbus<span>AI</span> Sales Portal</div></header>
      <nav>
        <a class="{cls('home')}" href="/">Dashboard</a>
        <a class="{cls('leads')}" href="/leads">Leads</a>
        <a class="{cls('notes')}" href="/notes">Notes</a>
        <a class="{cls('diag')}" href="/diagnostics">Diagnostics</a>
        <a class="{cls('admin')}" href="/admin">Admin</a>
      </nav>
      <main><h1>{title}</h1><p class="sub">{sub}</p>{body}</main>
    </body></html>""",
        mimetype="text/html",
    )


@app.route("/health")
def health():
    return jsonify(status="ok"), 200


@app.route("/")
def dashboard():
    q = request.args.get("q", "")
    try:
        leads = _items("lead")
        notes = _items("note")
    except PyMongoError as e:
        app.logger.error("DDS error: %s", e)
        return Response("Internal Server Error loading dashboard", status=500)
    # --- VULN #2: Reflected XSS: `q` echoed without escaping (CWE-79) --------
    search_note = f"<p class='sub'>Showing results for: {q}</p>" if q else ""
    body = f"""
      {search_note}
      <div class="cards">
        <div class="card"><div class="n">{len(leads)}</div><div class="l">Active leads</div></div>
        <div class="card"><div class="n">{len(notes)}</div><div class="l">Sales notes</div></div>
        <div class="card"><div class="n">$1.2M</div><div class="l">Pipeline (demo)</div></div>
      </div>
      <div class="panel">
        <form method="get" action="/"><div class="row">
          <input name="q" placeholder="Search the portal..."/>
          <button>Search</button>
        </div></form>
      </div>
    """
    return layout("home", "Sales Dashboard", "Your pipeline at a glance.", body)


@app.route("/leads")
def leads():
    try:
        rows = "".join(
            f"<tr><td>{i.get('name','')}</td><td>{i.get('company','')}</td>"
            f"<td><span class='pill'>{i.get('stage','New')}</span></td></tr>"
            for i in _items("lead")
        )
    except PyMongoError:
        return Response("Internal Server Error loading leads", status=500)
    body = f"""
      <div class="panel">
        <form method="post" action="/leads"><div class="row">
          <input name="name" placeholder="Contact name"/>
          <input name="company" placeholder="Company"/>
          <button>Add lead</button>
        </div></form>
      </div>
      <div class="panel">
        <table><tr><th>Contact</th><th>Company</th><th>Stage</th></tr>{rows or '<tr><td colspan=3>No leads yet.</td></tr>'}</table>
      </div>
    """
    return layout("leads", "Leads", "Track prospects through the pipeline.", body)


@app.route("/leads", methods=["POST"])
def add_lead():
    try:
        _coll().insert_one(
            {
                "id": str(uuid.uuid4()),
                "type": "lead",
                "name": request.form.get("name", ""),
                "company": request.form.get("company", ""),
                "stage": "New",
            }
        )
    except PyMongoError:
        return Response("Internal Server Error adding lead", status=500)
    return ("", 303, {"Location": "/leads"})


@app.route("/notes")
def notes():
    try:
        rows = "".join(
            f"<tr><td>{i.get('text','')}</td></tr>" for i in _items("note")
        )
    except PyMongoError:
        return Response("Internal Server Error loading notes", status=500)
    body = f"""
      <div class="panel">
        <form method="post" action="/notes"><div class="row">
          <input name="text" placeholder="Add a sales note"/>
          <button>Add note</button>
        </div></form>
      </div>
      <div class="panel"><table><tr><th>Note</th></tr>{rows or '<tr><td>No notes yet.</td></tr>'}</table></div>
    """
    return layout("notes", "Sales Notes", "Shared notes for the team.", body)


@app.route("/notes", methods=["POST"])
def add_note():
    try:
        _coll().insert_one(
            {
                "id": str(uuid.uuid4()),
                "type": "note",
                "text": request.form.get("text", ""),
            }
        )
    except PyMongoError:
        return Response("Internal Server Error writing note", status=500)
    return ("", 303, {"Location": "/notes"})


@app.route("/diagnostics")
def diagnostics():
    host = request.args.get("host", "")
    output = ""
    if host:
        # --- VULN #3: OS command injection: host passed to shell (CWE-78) ----
        try:
            output = subprocess.check_output(
                "ping -c 1 " + host, shell=True, stderr=subprocess.STDOUT
            ).decode(errors="ignore")
        except Exception as e:  # noqa
            output = str(e)
    body = f"""
      <div class="panel">
        <p class="sub">Network diagnostics tool: check connectivity to a host.</p>
        <form method="get" action="/diagnostics"><div class="row">
          <input name="host" placeholder="hostname or IP"/>
          <button>Run ping</button>
        </div></form>
      </div>
      <div class="panel"><pre>{output or 'No output yet.'}</pre></div>
    """
    return layout("diag", "Diagnostics", "Internal connectivity checks.", body)


@app.route("/admin")
def admin():
    body = """
      <div class="panel">
        <p class="sub">Administrative tools.</p>
        <div class="row"><a href="/admin/debug"><button>View runtime configuration</button></a></div>
      </div>
    """
    return layout("admin", "Admin Panel", "Operational settings and diagnostics.", body)


@app.route("/admin/debug")
def admin_debug():
    # --- VULN #4: No authentication + info disclosure (CWE-306) ---------------
    # Exposes all environment variables (including MONGO_PASSWORD from the Secret).
    return jsonify({k: v for k, v in os.environ.items()})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
