# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tiny localhost server: serves the prebuilt board HTML and does real mark-read.

    uv run serve.py [port]      # default 8770

The skill builds board.html (via generate_html.py) before starting this. The server only:
    GET  /          → serve board.html
    POST /api/mark  → body {"items":[{"channel_id","ts"}...]} → conversations.mark each
                      (REAL mark-read, via the shared slack_client)
Binds 127.0.0.1 only (no auth on /api/mark).
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "server"))
import slack_client as sc  # noqa: E402

# Runtime files live in DATA_DIR (not git-tracked), separate from this script.
DATA_DIR = os.path.expanduser("~/.config/slack-bridge")
HTML = os.path.join(DATA_DIR, "board.html")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.split("?")[0] != "/":
            self._send(404, "not found", "text/plain")
            return
        if not os.path.exists(HTML):
            self._send(404, "board.html not built yet — run the skill first.", "text/plain")
            return
        with open(HTML, "rb") as f:
            self._send(200, f.read(), "text/html; charset=utf-8")

    def do_POST(self):
        if self.path != "/api/mark":
            self._send(404, json.dumps({"ok": False, "error": "not found"}))
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            items = json.loads(self.rfile.read(length).decode()).get("items", [])
        except Exception as e:
            self._send(400, json.dumps({"ok": False, "error": str(e)}))
            return
        try:
            sl = sc.Slack.from_env()
            result = sc.mark_all_read(sl, items)
        except sc.SlackError as e:
            self._send(200, json.dumps({"ok": False, "error": str(e)}))
            return
        self._send(200, json.dumps(result))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8770
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Slack unread board → http://localhost:{port}", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
