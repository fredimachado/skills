# Coder brief

Coders start cold: none of your conversation, your reading, or the user's
words, and maybe none of these skills. Everything they need is in the brief,
and files travel by absolute path. Use this shape:

````markdown
You are a delegate. Do the work below directly. Do not orchestrate, start
subagents, push, or open, update or watch a pull request.

## Goal
<what this task achieves and why it matters to the larger change>

## Standards
Read and follow <absolute path to coding-standards/SKILL.md>. They are required.

## Plan
<absolute path to the plan file and the section for this task, or "none">

## Scope
- Files to create/change: <paths>
- Out of scope, do not touch: <paths / areas>

## Where to work
<absolute repository or worktree path>, branch `<branch>`.
Commit your work to this branch in small commits. Each message states why,
what changed, and how you proved it. Never push.

## Code sketches
<see below>

## Invariants (stateful or migration work)
- <invariant> — test: <test name that pins it>

## Tests to write first
<test names, what each asserts, where they live, and why each fails before the change>

## Verify
<exact commands for build, tests, lint, and what passing looks like; environment quirks>
<how to launch and drive the real application for this task: the driver or harness, the
user actions to perform, and what should be observed. Do this before reporting, and
report what you saw. If a scenario cannot be driven, say so instead of skipping it.>

## If the sketch does not fit reality
Small deviations: make them and list them in your report with the reason.
A deviation that changes a data shape, a public signature, or the behavior described here: stop and report instead of improvising.

## Report back
Summary · commit SHAs · files changed · tests run and their results · scenarios driven in
the real application and what you observed · anything you could not verify and why ·
deviations from the sketch · any TDD escape with its concrete reason · open questions ·
your action log.
````

## Code sketches

Required in every coding brief: take them from the plan's slice, or write
them yourself when there is no plan file. What a sketch contains and how it
is marked (binding, illustrative, new) is in `../../plan/references/sketches.md`,
the one copy of those rules.

## Fix message

Sent to the same coder (`delegate`, "Follow-ups go to the same delegate"). It
lists each finding by id with severity, `file:line`, what is wrong and what
correct looks like, and says: fix these and nothing else, commit, and report
the new head SHA and how each fix was proved.
