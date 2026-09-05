"""Tests for verify/report.py: CSV normalisation, HTML escaping, and the
one-file local server that --serve starts.

Nothing here binds anything but 127.0.0.1 and nothing reaches the network.
"""

from __future__ import annotations

import contextlib
import http.client
import http.server
import json
import re
import socket
import threading

import audit_common
import pytest
import report

# --- helpers ---------------------------------------------------------------

HEADER = ",".join(audit_common.PHASE2_COLUMNS)


def write_csv(tmp_path, rows, name="x.csv", newline="\n", encoding="utf-8"):
    """Write a phase 2 CSV from a list of dicts, with the requested line ending."""
    lines = [HEADER]
    for r in rows:
        lines.append(",".join('"' + str(r.get(c, "")).replace('"', '""') + '"'
                              for c in audit_common.PHASE2_COLUMNS))
    path = tmp_path / name
    path.write_bytes((newline.join(lines) + newline).encode(encoding))
    return str(path)


def js_const(html, name):
    """Read back a `const NAME = <json>;` line injected into the report."""
    m = re.search(rf"^const {re.escape(name)}\s*=\s*(.*);\s*$", html, re.M)
    assert m, f"no injected const {name} in the HTML"
    return json.loads(m.group(1).replace("<\\/", "</"))


def head_of(html):
    m = re.search(r"<head>(.*?)</head>", html, re.S)
    assert m, "no <head> in the HTML"
    return m.group(1)


@contextlib.contextmanager
def running(payload, token):
    """A report server on an ephemeral loopback port; always shut down."""
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), report.make_handler(payload, token))
    httpd.daemon_threads = True
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield httpd.server_address[1]
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=5)


def get(port, path):
    """GET one path, returning (status, headers, body); the socket is closed."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        return resp.status, resp.headers, resp.read()
    finally:
        conn.close()


def free_port_and_socket():
    """A listening loopback socket plus the port it holds, for the in-use test."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    return sock, sock.getsockname()[1]


ROW = {
    "App": "sonarr",
    "Title": "Some Show",
    "Year": "2019",
    "Episode": "S01E02",
    "DeclaredAudioLanguages": "Italian",
    "DetectedLanguage": "en",
    "Confidence": "0.91",
    "Verdict": audit_common.VERDICT_CONFIRMED,
    "Path": "/media/tv/Some Show/S01E02.mkv",
    "FileSize": "123",
    "FileMtime": "1700000000",
}


# --- R1: a </script> in the data cannot close the script block --------------
def test_r1_script_close_in_a_title_cannot_break_out_of_the_script_block(tmp_path):
    rows = report.read_rows(write_csv(tmp_path, [dict(ROW, Title="</script><img src=x>")]))

    html = report.build_html(rows, "x.csv")

    assert html.count("</script>") == 1
    assert "<\\/script>" in html
    assert js_const(html, "DATA") == rows


# --- R2: unicode and escapes survive the round trip -------------------------
def test_r2_unicode_and_escapes_round_trip_through_the_data_blob(tmp_path):
    title = "Perch\u00e8 caff\u00e8 'quoted' back\\slash \u00a0 \u2028 \u2029 \U0001f4c0"
    rows = report.read_rows(write_csv(tmp_path, [dict(ROW, Title=title)]))

    html = report.build_html(rows, "x.csv")

    assert js_const(html, "DATA")[0]["Title"] == title
    # ensure_ascii=False keeps accented characters readable in the page source.
    assert "caff\u00e8" in html
    # U+2028/U+2029 are legal JSON but terminate a line inside a <script>.
    assert "\u2028" not in html
    assert "\u2029" not in html


# --- R3: the page never assigns markup --------------------------------------
def test_r3_the_template_never_uses_inner_html_and_chips_are_built_from_nodes():
    template = report.HTML_TEMPLATE

    assert "innerHTML" not in template
    # The count inside a chip is its own <span class="n">, set via textContent.
    assert 'n.className = "n";' in template
    assert "n.textContent = count;" in template


# --- R4: rows are normalised to the display columns -------------------------
def test_r4_a_crlf_csv_is_normalised_to_the_display_columns(tmp_path):
    path = write_csv(tmp_path, [dict(ROW, Title="  padded  ")], newline="\r\n")

    rows = report.read_rows(path)

    assert list(rows[0]) == report.DISPLAY_COLUMNS
    assert "FileSize" not in rows[0]
    assert rows[0]["Title"] == "padded"
    assert all("\r" not in v for v in rows[0].values())


def test_r4_the_display_columns_are_the_phase2_columns_without_the_stat_fields():
    columns = report.DISPLAY_COLUMNS

    assert columns == [c for c in audit_common.PHASE2_COLUMNS if c not in ("FileSize", "FileMtime")]


# --- R5: a missing CSV is an error, not a traceback or a bare exit -----------
def test_r5_a_missing_csv_raises_report_error(tmp_path):
    with pytest.raises(report.ReportError) as excinfo:
        report.read_rows(str(tmp_path / "nope.csv"))

    assert "input CSV not found" in str(excinfo.value)


def test_r5_main_reports_a_missing_csv_and_returns_one(tmp_path, capsys):
    code = report.main([str(tmp_path / "nope.csv")])

    assert code == 1
    assert "input CSV not found" in capsys.readouterr().err


# --- R6: main writes the HTML next to the CSV, or where told -----------------
def test_r6_main_writes_the_html_beside_the_csv(tmp_path, capsys):
    csv_path = write_csv(tmp_path, [ROW])

    code = report.main([csv_path])
    capsys.readouterr()

    assert code == 0
    assert (tmp_path / "x.html").is_file()


def test_r6_main_honours_the_output_option(tmp_path, capsys):
    csv_path = write_csv(tmp_path, [ROW])
    out = tmp_path / "nested" / "custom.html"

    code = report.main([csv_path, "-o", str(out)])
    capsys.readouterr()

    assert code == 0
    assert out.is_file()
    assert not (tmp_path / "x.html").exists()


# --- R7: the handler gates on the token and sets safe headers ----------------
def test_r7_the_handler_serves_only_with_the_right_token():
    payload = b"<html>report</html>"
    token = "s3cret-token"  # noqa: S105

    with running(payload, token) as port:
        assert get(port, "/")[0] == 403
        assert get(port, "/?k=wrong")[0] == 403

        status, headers, body = get(port, f"/?k={token}")
        assert status == 200
        assert body == payload
        assert headers.get("Content-Length") == str(len(payload))
        assert headers.get("Content-Type") == "text/html; charset=utf-8"
        assert headers.get("Cache-Control") == "no-store"
        assert headers.get("Referrer-Policy") == "no-referrer"
        assert headers.get("X-Content-Type-Options") == "nosniff"

        # Any path serves the one report, provided the token is right.
        assert get(port, f"/anything?k={token}")[0] == 200


# --- R8: a non-ascii token candidate is a 403, not a crash -------------------
def test_r8_a_non_ascii_token_is_rejected_without_a_traceback(capsys):
    with running(b"<html></html>", "s3cret-token") as port:
        status, _, _ = get(port, "/?k=%C3%A9")

    assert status == 403
    assert "Traceback" not in capsys.readouterr().err


# --- R9: --no-token serves without a token ----------------------------------
def test_r9_without_a_token_the_report_is_served_to_anyone():
    payload = b"<html>open</html>"

    with running(payload, None) as port:
        status, _, body = get(port, "/")

    assert status == 200
    assert body == payload


# --- R10: browser noise never needs the token -------------------------------
@pytest.mark.parametrize("path", ["/favicon.ico", "/robots.txt"])
def test_r10_browser_chrome_requests_get_204_without_a_token(path):
    with running(b"<html></html>", "s3cret-token") as port:
        status, _, body = get(port, path)

    assert status == 204
    assert body == b""


# --- R11: the access log never leaks the token ------------------------------
def test_r11_the_request_log_never_echoes_the_token(capsys):
    token = "SUPERSECRETTOKEN123"  # noqa: S105

    with running(b"<html></html>", token) as port:
        assert get(port, f"/?k={token}")[0] == 200

    err = capsys.readouterr().err
    assert token not in err
    assert "GET /" in err


# --- R12/R13: serve() starts, announces itself and shuts down cleanly --------
def test_r12_serve_returns_on_enter_and_frees_the_port(monkeypatch, capsys):
    monkeypatch.setattr("builtins.input", lambda *a: "")

    report.serve("<html></html>", "127.0.0.1", 0, True)

    err = capsys.readouterr().err
    m = re.search(r"Serving the report on port (\d+)", err)
    assert m, err
    port = int(m.group(1))

    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.bind(("127.0.0.1", port))  # raises if the server is still bound
    finally:
        probe.close()


def test_r13_serve_prints_a_loopback_url_with_the_token_and_a_warning(monkeypatch, capsys):
    monkeypatch.setattr("builtins.input", lambda *a: "")

    report.serve("<html></html>", "127.0.0.1", 0, True)

    err = capsys.readouterr().err
    assert re.search(r"http://127\.0\.0\.1:\d+/\?k=\S+", err), err
    assert "treat the URL as sensitive" in err


# --- R14: the page is self-contained ----------------------------------------
def test_r14_the_page_loads_nothing_from_anywhere(tmp_path):
    html = report.build_html(report.read_rows(write_csv(tmp_path, [ROW])), "x.csv")
    head = head_of(html)

    assert "<script src=" not in html
    assert "<link " not in head
    assert "http://" not in head
    assert "https://" not in head


# --- R15: serving binds loopback unless asked otherwise ----------------------
def test_r15_the_default_bind_address_is_loopback():
    assert report.build_parser().get_default("host") == "127.0.0.1"


def test_r15_the_host_help_says_how_to_expose_it_on_the_lan():
    help_text = report.build_parser().format_help()

    assert "use 0.0.0.0 to expose on the LAN" in help_text


# --- R16: a CSV that is not UTF-8 is a clear error ---------------------------
def test_r16_a_non_utf8_csv_raises_a_report_error_mentioning_the_encoding(tmp_path):
    path = tmp_path / "latin1.csv"
    path.write_bytes(HEADER.encode() + b"\nsonarr,Perch\xe8,2019,,,,,,,,\n")

    with pytest.raises(report.ReportError) as excinfo:
        report.read_rows(str(path))

    assert "UTF-8" in str(excinfo.value)


# --- R17: a busy port fails cleanly -----------------------------------------
def test_r17_a_port_already_in_use_makes_main_return_one(tmp_path, capsys):
    csv_path = write_csv(tmp_path, [ROW])
    sock, port = free_port_and_socket()
    try:
        code = report.main([csv_path, "--serve", "--host", "127.0.0.1", "--port", str(port)])
    finally:
        sock.close()

    assert code == 1
    assert f"could not bind 127.0.0.1:{port}" in capsys.readouterr().err


# --- R18: verdict metadata comes from audit_common, unknowns still render ----
def test_r18_an_unknown_verdict_still_renders(tmp_path):
    rows = report.read_rows(write_csv(tmp_path, [dict(ROW, Verdict="BRAND_NEW_VERDICT")]))

    html = report.build_html(rows, "x.csv")

    assert js_const(html, "DATA")[0]["Verdict"] == "BRAND_NEW_VERDICT"


def test_r18_the_injected_verdict_meta_is_the_shared_one(tmp_path):
    html = report.build_html(report.read_rows(write_csv(tmp_path, [ROW])), "x.csv")

    assert js_const(html, "VERDICTS") == audit_common.VERDICT_META


def test_r18_the_injected_columns_are_the_display_columns(tmp_path):
    html = report.build_html(report.read_rows(write_csv(tmp_path, [ROW])), "x.csv")

    assert js_const(html, "COLUMNS") == report.DISPLAY_COLUMNS


# --- generated timestamp is injectable, so the page is reproducible ----------
def test_build_html_uses_the_supplied_generated_timestamp(tmp_path):
    html = report.build_html(report.read_rows(write_csv(tmp_path, [ROW])), "x.csv",
                             generated="2026-01-01 00:00:00")

    assert js_const(html, "GEN") == "2026-01-01 00:00:00"
    assert js_const(html, "SRC") == "x.csv"


# --- R19: the page does the expensive work once, not per keystroke -----------
def test_r19_the_table_script_is_written_for_large_reports():
    template = report.HTML_TEMPLATE

    # One collator, reused by the sort comparator.
    assert "Intl.Collator" in template
    assert "COLLATOR.compare" in template
    # A precomputed lowercased search haystack, not a concat per row per key.
    assert "_hay" in template
    # A cap on the rendered rows, with a way out.
    assert "ROW_CAP" in template
    assert "Show all " in template
    # Debounced search input.
    assert "SEARCH_DEBOUNCE_MS = 150" in template
    # Copy buttons are delegated, so the row loop attaches no listeners.
    assert "dataset.path" in template
    assert template.count('addEventListener("click"') <= 4


def test_r19_the_row_cap_is_two_thousand():
    assert "const ROW_CAP = 2000;" in report.HTML_TEMPLATE
