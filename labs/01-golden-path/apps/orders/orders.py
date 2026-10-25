#!/usr/bin/env python3
"""A tiny `orders` service.

It stands in for a real application so the labs have something plausible to
keep alive: it serves `/healthz`, `/readyz`, and `/orders`. The connection
string comes from the `ORDER_DB` environment variable, which is how the
bad-config scenario breaks it (the scenario points the app at a Secret that
does not exist, so the container cannot start).

The standard library only, so the image stays small.
"""
import json
import os
import sys
import http.server
import socketserver

PORT = int(os.environ.get("PORT", "8080"))
ORDER_DB = os.environ.get("ORDER_DB", "orders@localhost:5432/orders")
# The app loads an in-memory order index at startup. This is a real, bounded
# footprint (about 8 MiB) so that the OOM scenario in the labs is meaningful:
# the `6Mi` limit the scenario applies is genuinely too low for this app, which
# is why the container ends up OOMKilled rather than simply failing to start.
INDEX_SIZE_BYTES = 8 * 1024 * 1024


def main(argv) -> int:
    for arg in argv[1:]:
        print(f"orders: unrecognized option: {arg}", file=sys.stderr)
        print("orders: try 'orders --help' for the supported flags", file=sys.stderr)
        return 2

    index = bytearray(INDEX_SIZE_BYTES)  # in-memory order index
    print(f"orders: loaded in-memory index of {INDEX_SIZE_BYTES} bytes", flush=True)

    class Handler(http.server.BaseHTTPRequestHandler):
        def _send(self, code: int, body: str) -> None:
            data = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:
            if self.path in ("/healthz", "/readyz"):
                self._send(200, json.dumps({"status": "ok"}))
            elif self.path == "/orders":
                self._send(200, json.dumps({"service": "orders", "orders": []}))
            else:
                self._send(404, json.dumps({"error": "not found"}))

        def log_message(self, *args) -> None:
            pass

    with socketserver.ThreadingTCPServer(("0.0.0.0", PORT), Handler) as server:
        print(f"orders listening on :{PORT} (ORDER_DB={ORDER_DB})", flush=True)
        server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
