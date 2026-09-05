"""Regression coverage for report input preservation and template substitution."""

from __future__ import annotations

import os

import pytest
import report
from test_report import ROW, js_const, write_csv


@pytest.mark.parametrize("marker", [
    "__DATA_JSON__", "__SRC_JSON__", "__GEN_JSON__",
    "__VERDICT_META_JSON__", "__COLUMNS_JSON__",
])
def test_template_markers_in_csv_are_literal_data(marker):
    row = dict(ROW, Title=marker)
    html = report.build_html([row], "input.csv", generated="now")
    assert js_const(html, "DATA") == [row]


def test_template_markers_in_filename_and_timestamp_are_literal():
    html = report.build_html([], "__GEN_JSON__.csv", generated="__COLUMNS_JSON__")
    assert js_const(html, "SRC") == "__GEN_JSON__.csv"
    assert js_const(html, "GEN") == "__COLUMNS_JSON__"


@pytest.mark.parametrize("alias", ["same", "symlink", "hardlink"])
def test_output_cannot_overwrite_source_csv(tmp_path, alias, capsys):
    source = write_csv(tmp_path, [ROW])
    before = (tmp_path / "x.csv").read_bytes()
    output = tmp_path / "alias.html"
    if alias == "same":
        output = tmp_path / "x.csv"
    elif alias == "symlink":
        output.symlink_to(source)
    else:
        os.link(source, output)
    assert report.main([source, "-o", str(output)]) == 1
    assert (tmp_path / "x.csv").read_bytes() == before
    assert "input CSV" in capsys.readouterr().err


def test_failed_publication_preserves_previous_html(tmp_path, monkeypatch, capsys):
    source = write_csv(tmp_path, [ROW])
    output = tmp_path / "x.html"
    output.write_text("previous report", encoding="utf-8")

    def fail_replace(*args):
        raise OSError("disk unavailable")

    monkeypatch.setattr(os, "replace", fail_replace)
    assert report.main([source]) == 1
    assert output.read_text(encoding="utf-8") == "previous report"
    assert sorted(p.name for p in tmp_path.iterdir()) == ["x.csv", "x.html"]
    assert "disk unavailable" in capsys.readouterr().err


@pytest.mark.parametrize("alias", ["same", "symlink", "hardlink"])
@pytest.mark.parametrize("filename", ["movie.mkv", " movie.mkv "])
def test_output_cannot_overwrite_media_listed_in_report(tmp_path, alias, filename, capsys):
    media = tmp_path / filename
    media.write_bytes(b"media file")
    source = write_csv(tmp_path, [dict(ROW, Path=str(media))])
    output = tmp_path / "alias.html"
    if alias == "same":
        output = media
    elif alias == "symlink":
        output.symlink_to(media)
    else:
        os.link(media, output)
    assert report.main([source, "-o", str(output)]) == 1
    assert media.read_bytes() == b"media file"
    assert "media file" in capsys.readouterr().err


def test_media_path_whitespace_survives_read_and_html_copy_data(tmp_path):
    path = " /media/movie.mkv "
    rows = report.read_rows(write_csv(tmp_path, [dict(ROW, Path=path)]))
    assert rows[0]["Path"] == path
    assert js_const(report.build_html(rows, "input.csv"), "DATA")[0]["Path"] == path


@pytest.mark.parametrize("text", [
    "",
    "App,Title,Path\nsonarr,Example,/media/x.mkv\n",
    "Path,Verdict,Path\n/media/x.mkv,FILE_NOT_FOUND,/other.mkv\n",
    'Path,Verdict\n"unclosed,FILE_NOT_FOUND\n',
    "Path,Verdict\n/media/x.mkv,FILE_NOT_FOUND,extra\n",
])
def test_invalid_csv_does_not_replace_existing_report(tmp_path, text, capsys):
    source = tmp_path / "bad.csv"
    source.write_text(text, encoding="utf-8")
    output = tmp_path / "bad.html"
    output.write_text("previous report", encoding="utf-8")
    assert report.main([str(source)]) == 1
    assert output.read_text(encoding="utf-8") == "previous report"
    err = capsys.readouterr().err
    assert "CSV" in err or "parse" in err


@pytest.mark.parametrize("port", ["-1", "65536"])
def test_invalid_port_is_rejected_before_writing_report(tmp_path, port):
    source = write_csv(tmp_path, [ROW])
    with pytest.raises(SystemExit) as exc:
        report.main([source, "--serve", "--port", port])
    assert exc.value.code == 2
    assert not (tmp_path / "x.html").exists()
