# Lessons

Every user correction lands here: what went wrong, why, and the rule that
prevents it, stated so compliance can be checked.

## 2026-09-05 — finished subagents were left open

- **What went wrong:** analysis, implementer and reviewer subagents stayed
  listed as live teammates after delivering their result; the session pane
  filled with eleven agents and became unreadable.
- **Why:** the orchestration loop only tracked dispatch and report, never
  teardown.
- **Rule:** after reading a subagent's final report (and, for implementers,
  after its task's review is clean so no fix round can resume it), stop it
  with `TaskStop <name>` in the same turn. Before dispatching a new wave of
  agents, run `ListAgents` and stop every agent whose work is complete. Applies
  to every repository under `~/dev/`.

## 2026-09-05 — PR descriptions must be exhaustive

- **What went wrong:** the plan reduced the PR body to a four-bullet template
  (what/why/how to test/breaking); the user wants the maintainer to understand
  every change without reading the diff.
- **Why:** an external maintainer receiving a large unsolicited PR needs the
  reasoning, not just the list, or the PR stalls.
- **Rule:** before `gh pr create`, draft the body as a standalone document
  (findings→fix matrix with file:line and the pinning test, behaviour changes
  with migration notes, measured numbers with method, commit guide, what was
  deliberately not done, suggested review order, open questions) and review it
  like code. Applies to every PR opened from a repo under `~/dev/`.
