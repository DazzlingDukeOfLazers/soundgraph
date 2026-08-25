#!/usr/bin/env python3
"""Serve the repository for the web editor, without caching anything.

    python tools/serve.py [port]        # default 8177, then open /editor-web/

WHY THIS EXISTS. `python -m http.server` sends `Last-Modified` and no `Cache-Control`,
so a browser is free to apply heuristic caching — and Chrome does, to ES modules in
particular. The result is a page that keeps running yesterday's `app.js` after the file on
disk has changed, with no symptom except that a fix appears not to work. It cost three
rounds of "that is still broken" on code that was already fixed, twice while a stale
module was being blamed on the code it had been replaced by, and once the other way about.

Restarting the server does not help: the cache is keyed on the URL, not the connection.
Neither does a normal reload. `Cache-Control: no-store` on every response does, and for a
static file server on loopback the caching was never buying anything anyway.

The document root is the repository, not `editor-web/`, because the page loads patches
from `../examples/patches/`.
"""

import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        # no-store rather than no-cache: no-cache still stores the response and revalidates,
        # which leaves a 304 path where a stale module can come back.
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def guess_type(self, path):
        # Some Windows Python installs read the MIME table out of the registry, where .js
        # has been seen mapped to text/plain — which a browser refuses to execute as a
        # module, taking the whole page down with a MIME type error rather than a 404.
        if str(path).endswith((".js", ".mjs")):
            return "text/javascript"
        if str(path).endswith(".wasm"):
            return "application/wasm"
        return super().guess_type(path)

    def log_message(self, format, *args):
        # One line per request, without the date noise; a 404 here is usually the answer.
        sys.stderr.write("  %s\n" % (format % args))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8177
    handler = partial(NoCacheHandler, directory=str(ROOT))
    server = ThreadingHTTPServer(("127.0.0.1", port), handler)
    print(f"serving {ROOT} on http://127.0.0.1:{port}")
    print(f"the editor is at http://127.0.0.1:{port}/editor-web/")
    print("nothing is cached, so a plain reload always gets the current files\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
