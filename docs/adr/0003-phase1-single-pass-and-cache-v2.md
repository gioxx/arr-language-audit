# 3. Phase 1: one jq pass per payload, and a versioned Sonarr cache

- Status: accepted; cache identity and output publication extended by
  [ADR 0004](0004-cache-identity-and-output-integrity.md)
- Date: 2026-09-05
- Deciders: repository maintainers

## Context

Phase 1 turns the Radarr `/movie` payload, and one episode list per Sonarr
series, into CSV rows. The original implementation looped in bash over records,
calling `jq` once to pull a field, again to test the language tag, again to
quote a value: tens of thousands of processes on a few-thousand-file library,
with the scan spending its time in `fork`/`exec` rather than in the API. The
row-building rule was spread across bash and a dozen jq snippets, which is
where the empty-`audioLanguages` column-shift bug lived, and values crossed into
bash newline-delimited, so a title or path with a newline or tab could forge a
field boundary.

The Sonarr cache — a per-series signature of file count plus size on disk, so an
unchanged series is not re-fetched — was an unversioned JSON object whose rows
had been computed with `ITALIAN_REGEX`. Changing that regex, or the row format,
left the old rows in place and silently re-emitted them.

## Decision

**One jq program per payload.** Each API response goes to a single `jq`
invocation that emits the finished CSV rows and cache entries directly:
`JQ_RADARR` for the movie list, `JQ_SERIES` / `JQ_EPISODES` for Sonarr, over one
`JQ_DEFS` prelude (`clean`, `logsafe`, `csvq`, `pad2`). Quoting is a hand-written
`csvq` rather than `@csv`, to keep the exact row format the previous version
produced. The process count is now fixed overhead plus a constant per series,
and a warm cache makes it independent of library size — `tests/bats/scan.bats`
asserts a ceiling on it.

**A US byte is the field separator.** Values cross the jq/bash boundary
separated by `\x1f`, and `clean` strips that byte along with CR, LF and TAB from
every value jq emits. No title, path or language tag can forge a field boundary;
`logsafe` additionally strips the remaining control characters from anything
headed for a terminal.

**The cache carries a `__meta` block** with `version: 2` and the regex it was
built with. `JQ_CACHE_LOAD` returns the payload without `__meta` only when both
match, and the string `"FORMAT"` otherwise, so a cache from another version or
another `ITALIAN_REGEX` is discarded and rebuilt in the same pass that reads it.

The report is built in `<OUTPUT_CSV>.tmp.<pid>` and renamed into place, so a
reader never sees a partial file and a failed scan (exit 2) leaves the previous
report untouched.

## Consequences

- The jq programs are the definition of the row format, and they are long.
  Being single-quoted strings, every escape in them is jq's own: editing one
  means reading jq, not bash.
- Any future change to the row format or to `ITALIAN_REGEX` must bump the cache
  version, or users silently keep stale rows. That is now a one-line change in
  two jq programs, and the discard path is exercised by a test.
- A rename gives the report a new file's permissions rather than the previous
  file's — documented in `usage()` and the README, because an operator who had
  tightened the mode on the old report will not keep it.

## Alternatives considered

- **Keep the per-record loop and just fix the quoting.** Rejected: it leaves the
  process explosion, and the same quoting rule would still be stated in several
  places.
- **`@csv` for quoting.** Rejected: it would have changed the emitted row format
  for values the previous version quoted differently, breaking resume against an
  existing phase 2 CSV for no gain.
- **NUL as the separator.** Rejected: bash cannot hold a NUL in a variable.
- **Drop the cache and always re-fetch.** Rejected: Sonarr costs one request per
  series, and a large library is minutes of API time per run.
