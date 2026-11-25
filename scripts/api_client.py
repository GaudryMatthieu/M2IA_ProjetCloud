#!/usr/bin/env python3
"""Client de test de l'API via le front (/api). Sous-commandes : smoke | seed | verify | ping.

Exemples :
  api_client.py smoke --url http://127.0.0.1:8081                                   (docker compose)
  api_client.py smoke --url https://127.0.0.1:8443 --host dev.helpdesk.localtest.me (Kubernetes via Ingress)
"""
import argparse
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

STATE = Path(__file__).resolve().parent.parent / "results" / "state.json"
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE  # certificat auto-signé en local


class Client:
    def __init__(self, url, host=None):
        self.url, self.host, self.token = url.rstrip("/"), host, None

    def call(self, method, path, body=None, raw=None, ctype=None, timeout=15):
        headers = {}
        data = raw
        if body is not None:
            data, ctype = json.dumps(body).encode(), "application/json"
        if ctype:
            headers["Content-Type"] = ctype
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        if self.host:
            headers["Host"] = self.host
        req = urllib.request.Request(self.url + "/api" + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def jcall(self, *a, **k):
        code, data = self.call(*a, **k)
        try:
            return code, json.loads(data)
        except ValueError:
            return code, data

    def login(self, email, pwd, register=True):
        if register:
            self.jcall("POST", "/auth/register", {"email": email, "password": pwd})
        code, tok = self.jcall("POST", "/auth/login", {"email": email, "password": pwd})
        assert code == 200, f"login: {code} {tok}"
        self.token = tok["access_token"]

    def upload(self, tid, name, content):
        b = uuid.uuid4().hex
        body = (f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
                f"Content-Type: text/plain\r\n\r\n").encode() + content + f"\r\n--{b}--\r\n".encode()
        return self.jcall("POST", f"/tickets/{tid}/attachment", raw=body, ctype=f"multipart/form-data; boundary={b}")


def step(label, cond, detail=""):
    print(("  [OK]   " if cond else "  [FAIL] ") + label + (f"  ({detail})" if detail else ""))
    if not cond:
        sys.exit(1)


def wait_for(fn, timeout=40, every=1.5):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(every)
    return None


def cmd_smoke(c, a):
    print("Smoke test de la chaîne front -> API -> BDD -> stockage objet -> file -> worker")
    code, _ = c.call("GET", "/healthz")
    step("API joignable via le front", code == 200, f"HTTP {code}")
    code, _ = c.call("GET", "/readyz")
    step("API prête (base + stockage objet joignables)", code == 200, f"HTTP {code}")
    email, pwd = f"smoke-{uuid.uuid4().hex[:8]}@example.com", "Sm0ke-test-pwd"
    c.login(email, pwd)
    step("inscription + connexion JWT", c.token is not None)
    code, t = c.jcall("POST", "/tickets", {"title": "Smoke test", "description": "créé par api_client.py"})
    step("création d'un ticket (BDD)", code == 201, f"id={t.get('id')}")
    tid = t["id"]
    payload = b"contenu de la piece jointe " + uuid.uuid4().hex.encode()
    code, _ = c.upload(tid, "preuve.txt", payload)
    step("upload pièce jointe (stockage objet)", code == 200, f"HTTP {code}")
    code, data = c.call("GET", f"/tickets/{tid}/attachment")
    step("téléchargement identique", code == 200 and data == payload)
    if not a.skip_worker:
        done = wait_for(lambda: c.jcall("GET", f"/tickets/{tid}")[1].get("notified"))
        step("worker : notification traitée via RabbitMQ (notified=true)", bool(done))
        me = c.jcall("GET", "/me")[1]
        if me["is_agent"]:
            code, ex = c.jcall("POST", "/exports")
            step("export CSV demandé (202)", code == 202)
            got = wait_for(lambda: (lambda r: r[1] if r[0] == 200 else None)(c.call("GET", f"/exports/{ex['export_id']}")))
            step("worker : export CSV déposé dans le stockage objet", bool(got) and b"id,title" in got)
        else:
            print("  [SKIP] export CSV (utilisateur non agent : base non vierge)")
    print("=> SMOKE TEST RÉUSSI")


def cmd_seed(c, a):
    email, pwd = f"persist-{uuid.uuid4().hex[:8]}@example.com", "Persist-pwd-123"
    c.login(email, pwd)
    code, t = c.jcall("POST", "/tickets", {"title": f"persist-{uuid.uuid4().hex[:6]}"})
    step("ticket de référence créé", code == 201)
    STATE.parent.mkdir(exist_ok=True)
    STATE.write_text(json.dumps({"email": email, "pwd": pwd, "ticket": t["id"], "title": t["title"]}))
    print("état sauvegardé dans", STATE)


def cmd_verify(c, a):
    s = json.loads(STATE.read_text())
    c.login(s["email"], s["pwd"], register=False)
    code, t = c.jcall("GET", f"/tickets/{s['ticket']}")
    step("ticket toujours présent après l'incident (persistance PV)", code == 200 and t["title"] == s["title"])


def cmd_ping(c, a):
    code, _ = c.call("GET", "/healthz", timeout=3)
    print(code)
    sys.exit(0 if code == 200 else 1)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["smoke", "seed", "verify", "ping"])
    p.add_argument("--url", required=True)
    p.add_argument("--host")
    p.add_argument("--skip-worker", action="store_true")
    a = p.parse_args()
    try:
        {"smoke": cmd_smoke, "seed": cmd_seed, "verify": cmd_verify, "ping": cmd_ping}[a.cmd](Client(a.url, a.host), a)
    except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as exc:
        print("  [FAIL] connexion:", exc)
        sys.exit(2)
