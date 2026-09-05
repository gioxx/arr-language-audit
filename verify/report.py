#!/usr/bin/env python3
"""
Report generator for arr-language-audit phase 2.

Turns the CSV produced by verify_audio_language.py into a single
self-contained HTML file (inline CSS + JS, no external resources) that is
easy to browse, search, sort and filter. Optionally serves that file over
a tiny local webserver so you can open it from another machine, then shuts
down cleanly when you press Enter -- nothing is left running.

No third-party dependencies: standard library only.

Usage:
    ./verify/report.py [CSV] [-o HTML] [--serve] [--host HOST] [--port PORT]
    ./verify/report.py -h | --help

Arguments:
    CSV                verified-language-results.csv from phase 2
                       (default: <repo>/reports/verified-language-results.csv)

Options:
    -o, --output HTML  output HTML path
                       (default: the CSV path with a .html extension)
    --serve            after writing the HTML, serve it over HTTP and wait
    --host HOST        address to bind when serving (default: 0.0.0.0)
    --port PORT        port to bind when serving (default: 0 = pick a free one)
    --no-token         serve without the ?k=<token> access check
                       (anyone who can reach the port can read the report)

When serving, the URL includes a random token (?k=...). Requests without a
valid token get 403. The report contains full filesystem paths, so treat
the URL as sensitive and prefer an SSH tunnel on an untrusted network.

Exit codes:
    0   HTML written (and, with --serve, the server was stopped cleanly)
    1   input CSV not found / unreadable
"""

import argparse
import csv
import datetime
import http.server
import json
import os
import secrets
import socket
import sys
import threading
from pathlib import Path
from urllib.parse import parse_qs, urlparse

# Default location of the phase 2 CSV: <repo>/reports/ (this file is in
# <repo>/verify/), so it does not matter which directory you run this from.
DEFAULT_CSV = str(Path(__file__).resolve().parent.parent / "reports" / "verified-language-results.csv")

# Columns we expect from verify_audio_language.py, in display order.
COLUMNS = [
    "App", "Title", "Year", "Episode",
    "DeclaredAudioLanguages", "DetectedLanguage", "Confidence",
    "Verdict", "Path",
]


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


# ---------------------------------------------------------------------------
# CSV -> rows
# ---------------------------------------------------------------------------
def read_rows(csv_path: str) -> list[dict]:
    if not os.path.isfile(csv_path):
        log(f"ERROR: input CSV not found: {csv_path}")
        log("Run verify/verify-audio-language.sh first, or pass the correct path.")
        sys.exit(1)

    try:
        with open(csv_path, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            # Normalise every row to exactly the columns we know about, so a
            # slightly older/newer CSV still renders without surprises.
            rows = [{col: (r.get(col, "") or "").strip() for col in COLUMNS} for r in reader]
    except OSError as e:
        log(f"ERROR: could not read {csv_path}: {e}")
        sys.exit(1)

    return rows


# ---------------------------------------------------------------------------
# rows -> HTML
# ---------------------------------------------------------------------------
# The page renders the table from a JSON blob in JavaScript, building every
# cell with textContent, so nothing from the CSV (titles, paths) is ever
# interpreted as markup.
HTML_TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>arr-language-audit report</title>
<style>
  :root {
    --bg: #ffffff; --fg: #1c1e21; --muted: #6b7280; --border: #e2e5e9;
    --row: #f7f8fa; --accent: #2563eb;
    --ok-bg: #e7f6ec; --ok-fg: #1a7f37;
    --bad-bg: #fdecec; --bad-fg: #c1272d;
    --warn-bg: #fff4e2; --warn-fg: #9a6700;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #16181c; --fg: #e6e6e6; --muted: #9aa0a6; --border: #2c2f34;
      --row: #1e2126; --accent: #5b9dff;
      --ok-bg: #17311f; --ok-fg: #4ac26b;
      --bad-bg: #3a1c1e; --bad-fg: #ff6b6b;
      --warn-bg: #3a2f16; --warn-fg: #e2b23c;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 1.4rem;
    font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg); color: var(--fg);
  }
  h1 { font-size: 1.15rem; margin: 0 0 .2rem; }
  .sub { color: var(--muted); margin-bottom: 1rem; }
  .sub code { background: var(--row); padding: .1rem .3rem; border-radius: 3px; }

  .bar { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin-bottom: .9rem; }
  .chip {
    border: 1px solid var(--border); background: var(--bg); color: var(--fg);
    padding: .3rem .6rem; border-radius: 999px; cursor: pointer; font-size: .85rem;
    user-select: none;
  }
  .chip .n { color: var(--muted); }
  .chip.off { opacity: .4; }
  .chip.badge-ok.on   { background: var(--ok-bg);   border-color: var(--ok-fg); }
  .chip.badge-bad.on  { background: var(--bad-bg);  border-color: var(--bad-fg); }
  .chip.badge-warn.on { background: var(--warn-bg); border-color: var(--warn-fg); }

  .tools { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin-bottom: .6rem; }
  input[type=search] {
    flex: 1 1 260px; min-width: 180px;
    padding: .45rem .6rem; border: 1px solid var(--border); border-radius: 6px;
    background: var(--bg); color: var(--fg); font-size: .9rem;
  }
  button {
    padding: .45rem .7rem; border: 1px solid var(--border); border-radius: 6px;
    background: var(--bg); color: var(--fg); cursor: pointer; font-size: .85rem;
  }
  button:hover { border-color: var(--accent); }
  .count { color: var(--muted); font-size: .85rem; }

  .wrap { overflow-x: auto; border: 1px solid var(--border); border-radius: 8px; }
  table { border-collapse: collapse; width: 100%; font-size: .88rem; }
  th, td {
    text-align: left; padding: .5rem .6rem;
    border-bottom: 1px solid var(--border); vertical-align: top;
  }
  th {
    position: sticky; top: 0; background: var(--bg); cursor: pointer; white-space: nowrap;
    user-select: none;
  }
  th .arrow { color: var(--muted); font-size: .75rem; }
  tbody tr:nth-child(even) { background: var(--row); }
  td.path {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: .82rem; word-break: break-all;
  }
  td.num { text-align: right; white-space: nowrap; }
  .copy { margin-left: .4rem; padding: .05rem .35rem; font-size: .75rem; }

  .badge {
    display: inline-block; padding: .12rem .45rem;
    border-radius: 4px; font-size: .78rem; white-space: nowrap;
  }
  .badge-ok   { background: var(--ok-bg);   color: var(--ok-fg); }
  .badge-bad  { background: var(--bad-bg);  color: var(--bad-fg); }
  .badge-warn { background: var(--warn-bg); color: var(--warn-fg); }

  .empty { padding: 2rem; text-align: center; color: var(--muted); }
</style>
</head>
<body>
<h1>arr-language-audit &mdash; phase 2 report</h1>
<div class="sub">Source: <code id="src"></code> &nbsp;|&nbsp; generated <span id="gen"></span></div>

<div class="bar" id="chips"></div>

<div class="tools">
  <input type="search" id="q" placeholder="Filter by title, path, episode, language...">
  <button id="copyPaths">Copy visible paths</button>
  <span class="count" id="count"></span>
</div>

<div class="wrap">
  <table>
    <thead><tr id="head"></tr></thead>
    <tbody id="body"></tbody>
  </table>
  <div class="empty" id="empty" hidden>No rows match the current filters.</div>
</div>

<script>
"use strict";
const DATA = __DATA_JSON__;
const SRC  = __SRC_JSON__;
const GEN  = __GEN_JSON__;

document.getElementById("src").textContent = SRC;
document.getElementById("gen").textContent = GEN;

// Verdict -> badge style + short label.
const VERDICTS = {
  MISTAGGED_IS_ITALIAN:  {cls: "badge-ok",   label: "Mistagged (is Italian)"},
  CONFIRMED_NOT_ITALIAN: {cls: "badge-bad",  label: "Confirmed not Italian"},
  FILE_NOT_FOUND:        {cls: "badge-warn", label: "File not found"},
  EXTRACTION_FAILED:     {cls: "badge-warn", label: "Extraction failed"},
  DETECTION_FAILED:      {cls: "badge-warn", label: "Detection failed"},
};
function verdictMeta(v) {
  return VERDICTS[v] || {cls: "badge-warn", label: v || "(none)"};
}

const COLS = [
  {key: "App",                    label: "App"},
  {key: "Title",                  label: "Title"},
  {key: "Year",                   label: "Year"},
  {key: "Episode",                label: "Episode"},
  {key: "DeclaredAudioLanguages", label: "Declared"},
  {key: "DetectedLanguage",       label: "Detected"},
  {key: "Confidence",             label: "Confidence", num: true},
  {key: "Verdict",                label: "Verdict"},
  {key: "Path",                   label: "Path"},
];

const state = {
  q: "",
  hidden: new Set(),        // verdict values toggled off
  sortKey: "Verdict",
  sortDir: 1,
};

// --- summary chips -------------------------------------------------------
const counts = {};
for (const r of DATA) counts[r.Verdict] = (counts[r.Verdict] || 0) + 1;

const chips = document.getElementById("chips");
const totalChip = document.createElement("span");
totalChip.className = "chip";
totalChip.innerHTML = 'Total <span class="n">' + DATA.length + '</span>';
chips.appendChild(totalChip);

for (const v of Object.keys(counts).sort()) {
  const meta = verdictMeta(v);
  const c = document.createElement("span");
  c.className = "chip " + meta.cls + " on";
  c.dataset.verdict = v;
  c.innerHTML = meta.label + ' <span class="n">' + counts[v] + '</span>';
  c.addEventListener("click", () => {
    if (state.hidden.has(v)) { state.hidden.delete(v); c.classList.add("on"); c.classList.remove("off"); }
    else { state.hidden.add(v); c.classList.remove("on"); c.classList.add("off"); }
    render();
  });
  chips.appendChild(c);
}

// --- header ------------------------------------------------------------
const head = document.getElementById("head");
for (const col of COLS) {
  const th = document.createElement("th");
  th.textContent = col.label + " ";
  const arrow = document.createElement("span");
  arrow.className = "arrow";
  arrow.dataset.for = col.key;
  th.appendChild(arrow);
  th.addEventListener("click", () => {
    if (state.sortKey === col.key) state.sortDir *= -1;
    else { state.sortKey = col.key; state.sortDir = 1; }
    render();
  });
  head.appendChild(th);
}
const thCopy = document.createElement("th");
thCopy.textContent = "";
head.appendChild(thCopy);

// --- filtering / sorting --------------------------------------------------
function currentRows() {
  const q = state.q.toLowerCase();
  let rows = DATA.filter(r => !state.hidden.has(r.Verdict));
  if (q) {
    rows = rows.filter(r =>
      (r.Title + " " + r.Path + " " + r.Episode + " " +
       r.DetectedLanguage + " " + r.DeclaredAudioLanguages).toLowerCase().includes(q)
    );
  }
  const k = state.sortKey, dir = state.sortDir;
  rows = rows.slice().sort((a, b) => {
    let x = a[k], y = b[k];
    if (k === "Confidence" || k === "Year") {
      x = parseFloat(x) || 0; y = parseFloat(y) || 0;
      return (x - y) * dir;
    }
    return String(x).localeCompare(String(y), undefined, {numeric: true}) * dir;
  });
  return rows;
}

function fmtConfidence(v) {
  const n = parseFloat(v);
  return isNaN(n) ? "" : Math.round(n * 100) + "%";
}

function render() {
  const rows = currentRows();
  const body = document.getElementById("body");
  body.textContent = "";

  for (const r of rows) {
    const tr = document.createElement("tr");
    for (const col of COLS) {
      const td = document.createElement("td");
      if (col.key === "Verdict") {
        const meta = verdictMeta(r.Verdict);
        const span = document.createElement("span");
        span.className = "badge " + meta.cls;
        span.textContent = meta.label;
        td.appendChild(span);
      } else if (col.key === "Confidence") {
        td.className = "num";
        td.textContent = fmtConfidence(r.Confidence);
      } else if (col.key === "Path") {
        td.className = "path";
        td.textContent = r.Path;
      } else {
        if (col.num) td.className = "num";
        td.textContent = r[col.key];
      }
      tr.appendChild(td);
    }
    const tdCopy = document.createElement("td");
    if (r.Path) {
      const b = document.createElement("button");
      b.className = "copy";
      b.textContent = "copy";
      b.addEventListener("click", () => {
        navigator.clipboard.writeText(r.Path).then(() => {
          b.textContent = "ok"; setTimeout(() => (b.textContent = "copy"), 900);
        });
      });
      tdCopy.appendChild(b);
    }
    tr.appendChild(tdCopy);
    body.appendChild(tr);
  }

  document.getElementById("empty").hidden = rows.length !== 0;
  document.getElementById("count").textContent =
    rows.length + " / " + DATA.length + " rows";

  for (const a of document.querySelectorAll(".arrow")) {
    a.textContent = (a.dataset.for === state.sortKey) ? (state.sortDir > 0 ? "▲" : "▼") : "";
  }
}

document.getElementById("q").addEventListener("input", e => {
  state.q = e.target.value; render();
});

document.getElementById("copyPaths").addEventListener("click", () => {
  const paths = currentRows().map(r => r.Path).filter(Boolean).join("\n");
  navigator.clipboard.writeText(paths);
  const btn = document.getElementById("copyPaths");
  const old = btn.textContent;
  btn.textContent = "copied " + currentRows().filter(r => r.Path).length;
  setTimeout(() => (btn.textContent = old), 1200);
});

render();
</script>
</body>
</html>
"""


def build_html(rows: list[dict], csv_path: str) -> str:
    def js(value) -> str:
        # json.dumps then neutralise any "</" so the blob can't close <script>.
        return json.dumps(value, ensure_ascii=False).replace("</", "<\\/")

    generated = (datetime.datetime.now(datetime.timezone.utc)
                 .astimezone().strftime("%Y-%m-%d %H:%M:%S"))
    return (
        HTML_TEMPLATE
        .replace("__DATA_JSON__", js(rows))
        .replace("__SRC_JSON__", js(os.path.basename(csv_path)))
        .replace("__GEN_JSON__", js(generated))
    )


# ---------------------------------------------------------------------------
# Serving
# ---------------------------------------------------------------------------
def local_ipv4() -> str | None:
    """Best-effort guess of the machine's primary LAN IPv4, for the printed
    URL. No traffic is actually sent."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))  # TEST-NET-1, unroutable
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def make_handler(payload: bytes, token: str | None):
    class Handler(http.server.BaseHTTPRequestHandler):
        # Serve the one report for any path, provided the token matches.
        def do_GET(self):
            parsed = urlparse(self.path)

            if parsed.path in ("/favicon.ico", "/robots.txt"):
                self.send_response(204)
                self.end_headers()
                return

            if token is not None:
                got = parse_qs(parsed.query).get("k", [""])[0]
                if not secrets.compare_digest(got, token):
                    self.send_response(403)
                    self.send_header("Content-Type", "text/plain; charset=utf-8")
                    self.end_headers()
                    self.wfile.write(b"403 - missing or invalid access token (?k=...)\n")
                    return

            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, fmt, *args):
            # Concise, and never echo the token from the query string.
            path = self.path.split("?", 1)[0]
            log(f"  {self.address_string()} {self.command} {path} -> {args[1] if len(args) > 1 else ''}")

    return Handler


def serve(html_text: str, host: str, port: int, use_token: bool) -> None:
    # S104 below: serving on every interface is the documented point of --serve
    # (open the report from a phone on the LAN). The URL carries an access token
    # unless --no-token is passed, and the bind address is the caller's choice.
    payload = html_text.encode("utf-8")
    token = secrets.token_urlsafe(16) if use_token else None
    handler = make_handler(payload, token)

    httpd = http.server.ThreadingHTTPServer((host, port), handler)
    httpd.daemon_threads = True
    bound_host, bound_port = httpd.server_address[0], httpd.server_address[1]

    suffix = f"/?k={token}" if token else "/"
    log("")
    log(f"Serving the report on port {bound_port} (bound to {bound_host}).")
    log("Open one of:")
    shown = set()
    for h in (bound_host, "127.0.0.1", local_ipv4()):
        if not h or h in shown or h == "0.0.0.0":  # noqa: S104
            continue
        shown.add(h)
        log(f"  http://{h}:{bound_port}{suffix}")
    if bound_host == "0.0.0.0" and not shown:  # noqa: S104
        log(f"  http://<this-host>:{bound_port}{suffix}")
    if token:
        log("")
        log("The URL carries an access token; requests without it get 403.")
        log("The report contains full file paths - treat the URL as sensitive.")
    log("")

    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()

    try:
        input("Press Enter to stop the server... ")
    except (EOFError, KeyboardInterrupt):
        log("")
    finally:
        log("Stopping server.")
        httpd.shutdown()
        httpd.server_close()


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build an HTML report from the phase 2 CSV, and optionally serve it.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("csv", nargs="?", default=DEFAULT_CSV,
                        help="phase 2 CSV (default: <repo>/reports/verified-language-results.csv)")
    parser.add_argument("-o", "--output", default=None,
                        help="output HTML path (default: CSV path with .html)")
    parser.add_argument("--serve", action="store_true",
                        help="serve the HTML over HTTP and wait for Enter")
    parser.add_argument("--host", default="0.0.0.0",  # noqa: S104
                        help="bind address when serving (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=0,
                        help="bind port when serving (default: 0 = pick a free port)")
    parser.add_argument("--no-token", action="store_true",
                        help="serve without the ?k=<token> access check")
    args = parser.parse_args()

    rows = read_rows(args.csv)

    out_path = args.output or (os.path.splitext(args.csv)[0] + ".html")
    out_dir = os.path.dirname(os.path.abspath(out_path))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    html_text = build_html(rows, args.csv)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html_text)

    log(f"Wrote {out_path} ({len(rows)} row(s)).")

    if args.serve:
        serve(html_text, args.host, args.port, use_token=not args.no_token)


if __name__ == "__main__":
    main()
