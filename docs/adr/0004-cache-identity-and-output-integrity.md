# 4. Cache identity and output integrity

- Status: accepted
- Date: 2026-09-05
- Extends: [ADR 0003](0003-phase1-single-pass-and-cache-v2.md)

## Context

The hardened branch still treated failed Sonarr detail requests as successful
partial scans. Cache v2 could reuse rows from another Sonarr instance with the
same series ID and statistics. Predictable temporary filenames could follow a
pre-existing symlink; user-selected output destinations could replace media.

## Decision

Cache v3 records the normalized Sonarr URL and Italian regex in `__meta`.
Each series records its statistics, `[title, path, tvdbId, added]` identity,
flagged CSV rows and original media paths. Entries lacking valid statistics,
identity or paths cannot produce a hit. Older caches are rebuilt once.

Every API payload must be one JSON document of the expected shape. A failed
episode or episode-file request makes the scan incomplete, like failure of
the top-level list. Neither CSV nor cache is published on that path.

Original media paths include files whose tags are Italian: destination guards
must protect those files too, including on cached runs. Comparisons preserve
filename whitespace and cover aliases. Shell checks use Bash file identity
tests with a batched jq transport, keeping phase 1 free of a Python dependency
and avoiding per-file subprocesses.

Reports and caches are prepared in private, unpredictable sibling files and
renamed into place. They retain `0600` permissions. The cache is an optimization:
a cache publication failure is a warning after a valid CSV was published. CSV
and cache replacement are individually atomic, not a two-file transaction.

The worker and HTML builder validate CSV structure and refuse output paths
aliasing their input or listed media. HTML and the worker's initial snapshot
are prepared before replacement. The worker continues to append complete
results and flush each row for incremental resume; controlled interrupts retain
previous verdicts still pending replacement. This is not a journal guaranteeing
recovery from power loss, SIGKILL or an I/O failure mid-row.

## Consequences

- Warm cache runs retain the raw paths needed to protect output destinations,
  including Italian-tagged files. This adds cache storage proportional to paths.
- Tag-only changes still require `--refresh` or `FORCE_RESCAN=true`, because
  Sonarr's file count and disk size are not a content hash.
- Outputs are private by default. Sharing a generated report requires an
  explicit filesystem permission change or the report server.
- No refactoring of the pipeline into concurrent workers or database-backed
  state is needed for these fixes.
