# Review criteria

Review the diff, not the author's report. The report says where to look and
what was skipped; the code says what was done.

## Two kinds of finding

- **must-fix**: the change is wrong or unsafe to build on. Incorrect
  behavior, a broken contract from the plan, failing build or tests, a
  scenario that does not work when driven in the real application, data loss
  or a security hole, a behavior change with no test and no accepted
  justification, or a root cause hidden behind a guard.
- **should-fix**: it works, but leaves a real cost a careful maintainer would
  insist on removing. One decision living in two places, an edge case the
  intended use will reach left unhandled, a test that pins implementation
  instead of behavior, a misleading name on a public surface, code the
  intent does not need.

Leave everything else alone. Style preferences, naming taste, equally good
alternative approaches, and anything a formatter handles are not findings.
Neither are paths the change did not touch, rare cases the intended use will
not reach, small performance costs, or extra compatibility. Each round costs
a full fix turn, and nit-picks bury the findings that matter.

## The bar for a finding

Report a finding only when you can show how it goes wrong:

- **Behavior:** the input or state, the line that mishandles it, and the
  wrong result, crash, corruption or leak that follows.
- **Intent:** the item of the plan or the intent, and what the diff does
  instead or leaves undone.
- **Standards:** the line of the standards file, quoted, and the code that
  breaks it. If the file does not say it, it is not a rule.

Without that, read further until you have it, or drop the candidate. Read
past the diff: the changed functions in full, then their callers, then the
tests that cover them. Never cite a line, a call site or a behavior you have
not read, and label an inference as one. Check the intent and the caller's
check results against the code like any other claim. Finding nothing is a
valid result: do not raise findings to look thorough.

These are not findings either:

- a check the brief marks `(pre-existing)`
- what a compiler, a type checker or a linter reports on its own
- "needs more tests" or "needs more docs" that names no untested behavior
  or path that can break
- a behavior change that is the point of the change, reported as a
  regression

**Severity rule.** Severity follows what the change claimed or exercised,
not the fact that the standards were in the brief (they always are). Prefer
must-fix when the change claimed the behavior, ran TDD for a behavior
change, or touched migration, shared-state or crash-recovery invariants.
Prefer should-fix for Practice items (commit message shape, action log) and
for standards the change did not claim or exercise.

## Criteria, every round

Besides correctness and regressions in scope, check the coding standards,
especially:

- **Plan fit**: material divergence from the accepted plan without a
  recorded amendment. Must-fix or should-fix by how far it diverges.
- **TDD**: on behavior-changing work, a failing test before the production
  change, and the smallest change that passes. An escape without a concrete
  impracticality note is must-fix.
- **Behavior, not implementation**: tests exercise the caller's contract;
  hollow tests go.
- **Root causes**: no crash-hiding guard presented as a fix.
- **Attack the premise**: repeated failures of one gate that share an
  assumption. Must-fix to name and change that assumption.
- **Boundary and type discipline**: validate at the edge; illegal values
  unrepresentable; no silenced compiler.
- **Subtract before add**: complexity added without removing any.
- **Surplus**: code, tests, guards or options the intent does not need. Hold
  the change to the smallest one that does the job. Should-fix, and the fix
  is to remove them.
- **No bolted-on design**: a requirement patched onto a design that cannot
  hold it.
- **Idempotency and single writer**: must-fix when the change touches
  migration, shared state or crash recovery; otherwise should-fix.
- **Invariants**: each listed invariant has its test, and it passes.
- **Comments and stale text**: a comment that narrates the change or
  restates the code, or a doc, example or message the change made wrong.
  Should-fix. A missing comment is not a finding.
- **Commit quality and action log**: Practice; should-fix unless proof for a
  claimed must-fix behavior is missing.

## Risky work

When the brief names a risk (security, data loss or migration, concurrency
or shared state), look first where a failure is expensive, dangerous or hard
to see:

- **Trust boundaries and permissions**: input that reaches a sink unchecked,
  a check that can be bypassed, a secret in a log or a message.
- **Data loss and changes that cannot be undone.**
- **Partial failure**: the state left when a step fails halfway, and whether
  a retry or a second run is safe.
- **Races, ordering assumptions and stale state.**
- **Empty, missing, slow or failing dependencies.**
- **Compatibility and migration**: versions that run side by side, schema
  drift, existing data and existing users.
- **Hidden failure**: a swallowed error, a missing signal, success reported
  when the work did not happen.
- **The approach**: a premise the code contradicts, or a named simpler or
  safer design that reaches the same goal.

Something that works only on the happy path is a finding here. The bar for a
finding still holds.

## Reviewing a plan

Read the code each slice will change, then check the plan against it.
**must-fix**: coders following the plan as written would build something
wrong or get stuck. **should-fix**: it would work, at a cost a careful
maintainer would remove now. Look for:

- **Claims about the code**: every statement about what existing code does,
  takes or returns, checked at its `path:line`.
- **Order**: a slice that needs something no earlier slice provides, or that
  cannot pass its own checks when done alone.
- **Hollow verification**: a test or scenario that would still pass with the
  slice undone.
- **Guesswork**: a slice a coder would have to guess at. Name the open
  decision, two plausible readings, and how the results differ.
- **Approach**: a premise the code contradicts, work the code already does,
  or a named simpler or safer design that reaches the same goal.
- **Hidden scope**: callers, contracts, existing data or users the change
  touches and the plan does not name.
- **Standards**: a sketch that breaks the coding standards.

The bar for a finding holds: the plan section, the `path:line` it relies on,
and what breaks when the slice is carried out as written.

## Deciding on should-fix

Fix now when the fix is small and inside code the change already touches.
Defer to a later change when it widens the scope, touches unrelated code, or
needs a design decision of its own, and record the reason. When the review
budget is spent, defer rather than apply a fix nobody will review. Must-fix
items are never deferred; if one cannot be fixed, stop and tell the owner.

## Ledger

The caller keeps it; with `orchestrate` it lives in the task file.

| Id | Severity | Where | Finding | Raised by | Outcome |
|---|---|---|---|---|---|
| F1 | must-fix | `path/file.go:42` | what is wrong; what correct looks like | reviewer (harness/model) | fixed in `9ab0cde` |

Outcome is one of: open · fixed in `<sha>` · declined with evidence:
`<evidence>` · deferred: `<reason>` · disputed: both sides in one line each.
Ids are stable for the whole change and never reused. A finding that comes
back in a later round keeps its id. Mark a finding fixed only after you
checked the fix yourself.
