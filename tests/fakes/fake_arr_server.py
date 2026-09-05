#!/usr/bin/env python3
"""Fake Radarr/Sonarr API server for the bats suite.

One process serves both apps under URL-base prefixes (/radarr and /sonarr),
which real *arr supports, so the scripts under test build their URLs exactly as
they do in production. It binds 127.0.0.1 on an ephemeral port and never talks
to the network.

Usage: fake_arr_server.py <fixture-dir>

    <fixture-dir>/radarr/*.json and <fixture-dir>/sonarr/*.json back the routes.

Environment:
    FAKE_ARR_PORTFILE   the bound port is written here once the socket is up
    FAKE_ARR_LOG        JSONL request log: {"method","path","query","key_ok","body"}
    FAKE_ARR_CONTROL    JSON control file, re-read on every request:
                        {"fail_count": {"<path>": N}, "command_status": [...],
                         "crlf": false}
    FAKE_RADARR_KEY     expected X-Api-Key for /radarr (default "radarr-key")
    FAKE_SONARR_KEY     expected X-Api-Key for /sonarr (default "sonarr-key")
"""

from __future__ import annotations

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

APPS = ("radarr", "sonarr")
COMMAND_ID = 42

# Route (the part after /<app>/api/v3/) -> fixture file name.
STATIC_ROUTES = {
    "system/status": "system_status.json",
    "movie": "movies.json",
    "series": "series.json",
    "rootfolder": "rootfolder.json",
    "health": "health.json",
}

_lock = threading.Lock()
# One counter per app: a Radarr poll must not consume Sonarr's sequence.
_command_polls = {}


def _fixture_dir() -> Path:
    return Path(sys.argv[1]).resolve()


def _expected_key(app: str) -> str:
    if app == "radarr":
        return os.environ.get("FAKE_RADARR_KEY", "radarr-key")
    return os.environ.get("FAKE_SONARR_KEY", "sonarr-key")


def _read_control() -> dict:
    path = os.environ.get("FAKE_ARR_CONTROL")
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def _write_control(control: dict) -> None:
    path = os.environ.get("FAKE_ARR_CONTROL")
    if not path:
        return
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(control, handle)


def _log_request(entry: dict) -> None:
    path = os.environ.get("FAKE_ARR_LOG")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\n")


def _take_scheduled_failure(request_path: str) -> bool:
    """Consume one scheduled 500 for this path, if the control file has one."""
    with _lock:
        control = _read_control()
        remaining = control.get("fail_count", {}).get(request_path, 0)
        if not remaining:
            return False
        control["fail_count"][request_path] = remaining - 1
        _write_control(control)
        return True


def _next_command_status(app: str) -> str:
    """Next element of control.command_status for this app; the last repeats."""
    statuses = _read_control().get("command_status") or ["completed"]
    with _lock:
        polls = _command_polls.get(app, 0)
        _command_polls[app] = polls + 1
    return statuses[min(polls, len(statuses) - 1)]


def _resolve_fixture(app: str, route: str, query: dict) -> Path | None:
    if route in STATIC_ROUTES:
        return _fixture_dir() / app / STATIC_ROUTES[route]
    if route == "episode":
        series_ids = query.get("seriesId")
        if series_ids:
            return _fixture_dir() / app / f"episodes_{series_ids[0]}.json"
        return None
    if route.startswith("episodefile/"):
        return _fixture_dir() / app / f"episodefile_{route.split('/', 1)[1]}.json"
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeArr/1.0"

    def log_message(self, *args):
        """Silence the stdlib access log; the JSONL log is the contract."""

    # -- plumbing ---------------------------------------------------------

    def _send(self, status: int, payload) -> None:
        if isinstance(payload, (dict, list)):
            body = json.dumps(payload, indent=2).encode("utf-8")
        else:
            body = str(payload).encode("utf-8")
        if _read_control().get("crlf"):
            body += b"\r\n"
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> str:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return ""
        return self.rfile.read(length).decode("utf-8", "replace")

    # -- request handling -------------------------------------------------

    def do_GET(self) -> None:
        self._handle("GET")

    def do_POST(self) -> None:
        self._handle("POST")

    def _handle(self, method: str) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        body = self._read_body() if method == "POST" else ""

        segments = [s for s in parsed.path.split("/") if s]
        app = segments[0] if segments and segments[0] in APPS else ""
        rest = "/".join(segments[1:]) if app else "/".join(segments)
        key_ok = self.headers.get("X-Api-Key") == _expected_key(app or "radarr")

        _log_request(
            {
                "method": method,
                "path": parsed.path,
                "query": parsed.query,
                "key_ok": key_ok,
                "body": body,
            }
        )

        status, payload = self._dispatch(
            method, app, rest, query, key_ok=key_ok, request_path=parsed.path
        )
        self._send(status, payload)

    def _dispatch(self, method, app, rest, query, *, key_ok, request_path):
        """Everything that is true of a request regardless of the route."""
        # /ping is the one unauthenticated route, as in real *arr.
        if rest == "ping":
            return 200, {"status": "OK"}
        if not app:
            return 404, {"message": "Unknown app"}
        if not key_ok:
            return 401, {"message": "Unauthorized"}
        if _take_scheduled_failure(request_path):
            return 500, {"message": "Scheduled failure"}
        if not rest.startswith("api/v3/"):
            return 404, {"message": "Not found"}
        return self._api_response(method, app, rest[len("api/v3/"):], query)

    def _api_response(self, method, app, route, query):
        """The /api/v3 routes themselves."""
        if route == "command" and method == "POST":
            return 201, {"id": COMMAND_ID, "status": "queued"}
        if route == f"command/{COMMAND_ID}" and method == "GET":
            return 200, {"id": COMMAND_ID, "status": _next_command_status(app)}
        if method != "GET":
            return 405, {"message": "Method not allowed"}
        fixture = _resolve_fixture(app, route, query)
        if fixture is None or not fixture.exists():
            return 404, {"message": f"No fixture for {route}"}
        return 200, json.loads(fixture.read_text(encoding="utf-8"))


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    if not _fixture_dir().is_dir():
        print(f"fake_arr_server: no such fixture directory: {sys.argv[1]}", file=sys.stderr)
        return 2

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]

    portfile = os.environ.get("FAKE_ARR_PORTFILE")
    if portfile:
        # Write-then-rename so a poller never reads a half-written port.
        tmp = portfile + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(str(port))
        os.replace(tmp, portfile)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
