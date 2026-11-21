# Task file

Create it before the first coder starts. Put it in the session scratchpad
directory if the environment provides one, otherwise the OS temp directory,
named `orchestrate-<slug>-<YYYYMMDD>.md`. Keep it outside the repository so
no `git add` picks it up and every worktree sees the same file. Tell the user
its absolute path. If a task file for this work already exists, read it and
continue from it, after reading again every file it lists under "Skills in
use". First fetch and compare the base with the recorded base SHA. If it
moved, read what landed before you continue: work that sat can describe code
that changed since, or solve a problem someone else already solved. Record
what you found under Decisions.

You are its only writer. Write each entry when it happens, not at the end.

````markdown
# Orchestration: <title>

> Orchestrator: after a context summary or a resume, read every file under
> "Skills in use" again before your next action. Their rules still hold.

- **Goal:** <one or two sentences>
- **Finish condition:** local | open-for-review | merge-ready
- **Where:** <branch / worktree path(s)>, base `<base branch>` at `<base SHA>`
- **Plan:** <absolute path of the plan file, or "inline below">
- **Started:** <date>
- **Issues:** Resolves #<n> (the owner said this work fixes it) | Related #<n> | none
- **PR:** <link, once opened>

## Skills in use
- <absolute path>/orchestrate/SKILL.md, and its references/brief.md,
  review.md and task-file.md
- <absolute path of each other skill file this run follows, added when you
  first use it: coding-standards, delegate and its references/hosts.md,
  plan, review-loop, council, file-pr, babysit-pr>

## Verification plan
- <behavior> — driven with <driver/harness>: <user actions> → <what the user should observe>
- Reproduction (fixes only): <user actions> → failed at `<base SHA>`: <what was seen>
- Before shots (visible changes only): <image paths, taken at `<base SHA>`> (or "none")
- Harness to build: <what, as task Tn> (or "none needed")
- Cannot be verified by an agent: <what and why> (or "nothing")

## Baseline
- <build/test/lint command> at `<base SHA>` → pass | fail: <test and error>
- Could not run here: <check and why> (or "nothing")

## Tasks
- [ ] T1 — <task> · complexity: low|medium|complex · role: coder-simple → <harness>/<model>/<effort> · agent: <id>
- [ ] T2 — <task> · depends on T1 · ...

## Plan gate
- <gate line> → pass | fail: <gap>, searched <what> → <result>
- Revision: none | 1 (planner session <id>) → pass | fail

## Plan review
- Reviewer: reviewer · <harness>/<model> (or council-a and council-b, each
  with harness/model) → APPROVE | CHANGES
- Not covered: <what, and whether you covered it yourself>
- Revision: none | 1 (planner session <id>) → gate pass | fail, findings closed: <ids>

## Rounds
| Task | Round | Base SHA | Reviewed head SHA | Reviewer (role · harness/model) | Verdict | Open must-fix | Diff (`--shortstat`) |
|---|---|---|---|---|---|---|---|
| T1 | 1 | abc1234 | def5678 | reviewer · <harness>/<model> | changes | F1 | 4 files, +120 -15 |

## Council (risky work only)
| Round | Head SHA | council-a (harness/model) | council-b (harness/model) |
|---|---|---|---|
| 1 | def5678 | CHANGES | APPROVE |

## Findings ledger
| Id | Task | Severity | Where | Finding | Raised by | Outcome |
|---|---|---|---|---|---|---|
| F1 | T1 | must-fix | `path/file.go:42` | <what is wrong; what correct looks like> | reviewer | fixed in `9ab0cde` |
| F2 | T1 | should-fix | `path/file.go:88` | <...> | orchestrator | deferred: <reason> |

Outcome is one of: open · fixed in `<sha>` · declined with evidence: <evidence> ·
deferred: <reason> · disputed: <both sides in one line each>.
Ids are stable for the whole feature and never reused. A finding that comes
back in a later round keeps its id.

## Deferred
- F2 (T1) — <what>, why deferred, suggested follow-up (separate PR / issue)
- Noticed by the T1 coder, left alone — <what>, suggested follow-up

## Decisions
- <date/time> — <decision> — <why> — decided by: owner | default | orchestrator
- <date/time> - <role> fallback - <quota signal, original selection and session, fallback selection and session> - decided by: owner configuration

## Verification
- Verified at `<head SHA>`, in a clean checkout or worktree at that commit
- <build/test command> → <result>
- New tests fail without the change: <how checked> → <result>
- <scenario driven in the real app> → <what was observed>
- Reproduction run again at `<head SHA>` → <what was observed>
- Not verified: <what and why>

## Last verified state
<written when the owner says stop or a cap stops the work: reviewed head SHA,
what is pushed, open findings by id>
````

Tick a task only when its review is approved and its behavior has been seen
working in the driven application. Mark a finding fixed only after you have
re-checked the fix yourself. Record under Decisions: where the work happens,
the role for anything not obvious, parallelization, every open decision from
the plan, every deviation from the plan you accepted, every deferral, every
cap reached, and any escalation. Say who decided each: the owner, a
conventional default, or you.
