"""Preview the checked-in site with Python's standard library; no build step."""
import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

BASE = "/godot-mcp-go"
ROOT = Path(__file__).resolve().parent / "site"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def translate_path(self, path):
        return super().translate_path(path[len(BASE):])

    def valid_path(self):
        path = urlsplit(self.path).path
        if path in {"/", BASE}:
            self.send_response(302)
            self.send_header("Location", BASE + "/")
            self.end_headers()
            return False
        if not path.startswith(BASE + "/"):
            self.send_error(404)
            return False
        return True

    def do_GET(self):
        if self.valid_path():
            super().do_GET()

    def do_HEAD(self):
        if self.valid_path():
            super().do_HEAD()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=4321)
    args = parser.parse_args()
    print(f"Serving {ROOT} at http://127.0.0.1:{args.port}{BASE}/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
