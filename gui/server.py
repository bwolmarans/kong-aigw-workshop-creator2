#!/usr/bin/env python3
"""Local web GUI for provision-ai-gateways.sh. stdlib only, no dependencies.

Run: python3 gui/server.py
Then open http://localhost:8765 in Chrome.
"""
import http.server
import json
import os
import subprocess
import threading
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROVISION_SCRIPT = os.path.join(ROOT, "provision-ai-gateways.sh")
ENCRYPT_SCRIPT = os.path.join(ROOT, "encrypt-artifacts.sh")
DECRYPT_SCRIPT = os.path.join(ROOT, "decrypt-artifacts.sh")
PREFLIGHT_SCRIPT = os.path.join(ROOT, "preflight-check.sh")

# job_id -> {"proc": Popen, "lines": [str], "done": bool}
JOBS = {}


def run_job(args, stdin_text="", extra_env=None):
    """Spawn args as a subprocess, feed stdin_text, capture merged stdout/stderr
    into a job dict that /api/poll/<id> can be polled against."""
    job_id = uuid.uuid4().hex
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)

    proc = subprocess.Popen(
        args,
        cwd=ROOT,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env=env,
    )
    job = {"proc": proc, "lines": [], "done": False}
    JOBS[job_id] = job

    def feed_stdin():
        try:
            proc.stdin.write(stdin_text)
            proc.stdin.close()
        except Exception:
            pass

    def read_stdout():
        for line in proc.stdout:
            job["lines"].append(line.rstrip("\n"))
        proc.wait()
        job["done"] = True
        job["returncode"] = proc.returncode

    threading.Thread(target=feed_stdin, daemon=True).start()
    threading.Thread(target=read_stdout, daemon=True).start()
    return job_id


def build_stdin(payload):
    """Build the text fed to the script's interactive prompts.

    Order matches provision-ai-gateways.sh: vault key/value pairs terminated
    by a blank line.
    """
    lines = []
    for kv in payload.get("vault", []):
        key = (kv.get("key") or "").strip()
        val = kv.get("value") or ""
        if not key:
            continue
        lines.append(key)
        lines.append(val)
    lines.append("")  # blank line ends vault key collection

    return "\n".join(lines) + "\n"


def build_args(payload):
    args = [PROVISION_SCRIPT, "--apply-automatically"]

    def add(flag, key):
        val = payload.get(key)
        if val:
            args.extend([flag, str(val)])

    add("--konnect_pat", "pat")
    add("--org", "org")
    add("--namespace", "namespace")
    add("--region", "region")

    if payload.get("router_only"):
        args.append("--router-only")
    else:
        add("--prefix", "prefix")
        add("--range", "range")

    return args


def start_provision_job(payload):
    return run_job(build_args(payload), build_stdin(payload))


def start_preflight_job():
    return run_job([PREFLIGHT_SCRIPT, "--fix"])


def start_encrypt_job(payload, decrypt=False):
    org = (payload.get("org") or "").strip()
    passphrase = payload.get("passphrase") or ""
    if not org:
        raise ValueError("org is required")
    if not passphrase:
        raise ValueError("passphrase is required")
    script = DECRYPT_SCRIPT if decrypt else ENCRYPT_SCRIPT
    return run_job([script, org], extra_env={"DEPLOY_ARTIFACTS_PASSPHRASE": passphrase})


INDEX_HTML_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")


class Handler(http.server.BaseHTTPRequestHandler):
    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            with open(INDEX_HTML_PATH, "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/api/poll/"):
            job_id = self.path.split("/api/poll/", 1)[1]
            job = JOBS.get(job_id)
            if not job:
                self._send_json({"error": "unknown job"}, 404)
                return
            self._send_json(
                {
                    "lines": job["lines"],
                    "done": job["done"],
                    "returncode": job.get("returncode"),
                }
            )
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/api/run":
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length) or b"{}")
            job_id = start_provision_job(payload)
            self._send_json({"job_id": job_id})
        elif self.path == "/api/preflight":
            job_id = start_preflight_job()
            self._send_json({"job_id": job_id})
        elif self.path in ("/api/encrypt", "/api/decrypt"):
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length) or b"{}")
            try:
                job_id = start_encrypt_job(payload, decrypt=(self.path == "/api/decrypt"))
                self._send_json({"job_id": job_id})
            except ValueError as e:
                self._send_json({"error": str(e)}, 400)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass


def main():
    port = 8765
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"AI Gateway Workshop GUI running at http://localhost:{port}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
