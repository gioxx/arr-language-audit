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
