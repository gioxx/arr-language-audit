"""Constants and helpers shared by the phase 2 worker and the report builder.

Kept import-light and dependency-free so both the scripts and the tests can
import it under any supported interpreter.
"""

from __future__ import annotations

import sys
from pathlib import Path

MIN_PYTHON = (3, 9)

REPO_ROOT = Path(__file__).resolve().parent.parent
REPORTS_DIR = REPO_ROOT / "reports"
PHASE1_CSV = REPORTS_DIR / "missing-italian-audio.csv"
PHASE2_CSV = REPORTS_DIR / "verified-language-results.csv"
REPORT_HTML = REPORTS_DIR / "verified-language-results.html"

PHASE1_COLUMNS = ["App", "Title", "Year", "Episode", "AudioLanguages", "Path"]
PHASE2_COLUMNS = [
    "App",
    "Title",
    "Year",
    "Episode",
    "DeclaredAudioLanguages",
    "DetectedLanguage",
    "Confidence",
    "Verdict",
    "Path",
    "FileSize",
    "FileMtime",
]

VERDICT_MISTAGGED = "MISTAGGED_IS_ITALIAN"
VERDICT_CONFIRMED = "CONFIRMED_NOT_ITALIAN"
VERDICT_LOW_CONFIDENCE = "LOW_CONFIDENCE"
VERDICT_FILE_NOT_FOUND = "FILE_NOT_FOUND"
VERDICT_EXTRACTION_FAILED = "EXTRACTION_FAILED"
VERDICT_DETECTION_FAILED = "DETECTION_FAILED"

ERROR_VERDICTS = frozenset(
    {VERDICT_FILE_NOT_FOUND, VERDICT_EXTRACTION_FAILED, VERDICT_DETECTION_FAILED}
)
RETRYABLE_VERDICTS = ERROR_VERDICTS | {VERDICT_LOW_CONFIDENCE}
ALL_VERDICTS = [
    VERDICT_MISTAGGED,
    VERDICT_CONFIRMED,
    VERDICT_LOW_CONFIDENCE,
    VERDICT_FILE_NOT_FOUND,
    VERDICT_EXTRACTION_FAILED,
    VERDICT_DETECTION_FAILED,
]

# Label + css class used by report.py; the report's JS reads this as JSON.
VERDICT_META = {
    VERDICT_MISTAGGED: {"cls": "badge-ok", "label": "Mistagged (is Italian)"},
    VERDICT_CONFIRMED: {"cls": "badge-bad", "label": "Confirmed not Italian"},
    VERDICT_LOW_CONFIDENCE: {"cls": "badge-warn", "label": "Low confidence"},
    VERDICT_FILE_NOT_FOUND: {"cls": "badge-warn", "label": "File not found"},
    VERDICT_EXTRACTION_FAILED: {"cls": "badge-warn", "label": "Extraction failed"},
    VERDICT_DETECTION_FAILED: {"cls": "badge-warn", "label": "Detection failed"},
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def check_python_floor() -> None:
    if sys.version_info < MIN_PYTHON:
        log(
            f"ERROR: Python {MIN_PYTHON[0]}.{MIN_PYTHON[1]}+ is required, "
            f"found {sys.version.split()[0]}."
        )
        sys.exit(1)
