#!/usr/bin/env python3
"""Serves a built package's ui/ (from a build's target dir) and runs its api.cgi with a stub sign-in.
    chassis/tests/devserver.py --ui <target/ui> --var DIR --share DIR [--admins none] [--port 8787]"""
import argparse, os, subprocess
from http.server import HTTPServer, SimpleHTTPRequestHandler
here = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser(); ap.add_argument("--ui", required=True); ap.add_argument("--var", required=True); ap.add_argument("--share", required=True)
ap.add_argument("--pkg", default=""); ap.add_argument("--user", default=os.environ.get("USER", "tom")); ap.add_argument("--port", type=int, default=8787); ap.add_argument("--admins", default="")
a = ap.parse_args(); ui = os.path.abspath(a.ui)
class H(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kw): super().__init__(*args, directory=ui, **kw)
    def cgi(self, method):
        qs = self.path.split("?", 1)[1] if "?" in self.path else ""; length = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(length) if length else b""
        env = dict(os.environ, REQUEST_METHOD=method, QUERY_STRING=qs, CONTENT_LENGTH=str(length) if length else "", CHASSIS_VAR=a.var, CHASSIS_SHARE=a.share, CHASSIS_PKG=a.pkg or os.path.dirname(ui),
                   CHASSIS_AUTH_CGI=os.path.join(here, "stub-auth.sh"), STUB_USER=a.user, CHASSIS_ADMINS=(a.admins or subprocess.run(["id", "-gn"], capture_output=True, text=True).stdout.strip()))
        out = subprocess.run(["bash", os.path.join(ui, "api.cgi")], input=body, capture_output=True, env=env).stdout
        head, _, payload = out.partition(b"\r\n\r\n"); status, headers = 200, []
        for line in head.decode(errors="replace").split("\r\n"):
            k, _, v = line.partition(": ")
            if k == "Status": status = int(v.split()[0])
            elif k: headers.append((k, v))
        self.send_response(status); [self.send_header(k, v) for k, v in headers]; self.end_headers(); self.wfile.write(payload)
    def do_GET(self): return self.cgi("GET") if self.path.startswith("/api.cgi") else super().do_GET()
    def do_POST(self): return self.cgi("POST") if self.path.startswith("/api.cgi") else self.send_error(405)
    def end_headers(self): self.send_header("Cache-Control", "no-store"); super().end_headers()
    def log_message(self, *args): pass
print(f"http://127.0.0.1:{a.port}/panel.html  (ui {ui}, var {a.var}, as {a.user})", flush=True)
HTTPServer(("127.0.0.1", a.port), H).serve_forever()
