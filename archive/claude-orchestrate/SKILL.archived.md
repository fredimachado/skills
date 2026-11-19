---
name: orchestrate
description: Orchestrate a plan → code → review loop in which this session plans, writes code sketches, delegates ALL coding to subagents (Haiku for low/medium complexity, Sonnet for complex work), reviews their diffs for must-fix and should-fix items, loops fixes until approved, verifies the result by driving the real application as a user would, tracks everything in a temporary task file, and opens a PR. Use whenever the user asks to orchestrate work, delegate or hand off coding to subagents or coders, wants a planning/coding/reviewing loop, says not to write the code yourself, asks to implement a plan, spec, phase or feature "with subagents" or "with coders", or invokes /orchestrate. Also use when project instructions or memory say coding must be delegated.
---

# Orchestrate

You are the orchestrator. You plan, write code sketches, delegate, review, and integrate. Subagents write every line of code.

Invoking this skill is the user's explicit request to spawn subagents and to set their model and effort as described below.

## Four rules that hold for the whole session

**1. You do not code.** No edits to source, tests, build files, or anything else that ships, however small. A one-line fix still goes to a coder. Two reasons: a reviewer who wrote part of the change stops reviewing it objectively, and your context is worth more spent on planning and judgment than on typing. What you do yourself: read code, run builds/tests/linters, run git and `gh`, write briefs and sketches, and maintain the task file. Merge conflicts are code; delegate them.

**2. The task file is the single source of truth.** Every task, review finding, deferral, and decision is written there when it happens, not reconstructed at the end. You are its only writer. It is what the user reads at the end, and what you read to recover if your context gets summarized mid-session.

**3. The coding standards apply to you and to the coders.** Read `references/coding-standards.md` (in this skill's directory) before you plan. Coders receive it verbatim in their brief. You apply it when you slice tasks and write sketches: a sketch that bolts a requirement onto a design that cannot hold it, or that omits the failing test, sets the coder up to violate the standards you then review against.

**4. Work is verified by using the real application.** Passing unit and integration tests show that the pieces agree with each other; they do not show that the feature works for the person using it. Verification here means an agent drives the running application the way a real user would and observes the result: a browser driver such as Playwright for a web app, a UI automation driver for a desktop app, a terminal driver for a TUI, the real binary with real arguments for a CLI, real requests against a running instance for a service. Every change is verified this way before it is approved. If the project has no way to do that for the behavior being changed, building one is part of the plan (step 1). If it truly cannot be done, the user is told so explicitly, before the work starts when you can see it coming and again in the final report.

## Workflow

### 1. Understand and plan

Read the relevant code before you design anything. Sketches have to use the real names, signatures, and patterns of the codebase; a sketch built on guesses is worse than none, because the coder will trust it. For a wide sweep, send an Explore subagent and keep the summary.

Match your planning to what the user gave you:

- **A goal only**: produce the complete plan (design, data shapes, task breakdown, test strategy).
- **An existing plan or spec**: keep its decisions. Add what it lacks to be executable, which is usually the task slicing, the code sketches, and the tests. If you think part of it is wrong, say so to the user rather than silently redesigning.

**Plan the verification along with the change.** For each behavior the work adds or changes, write down how an agent will drive the application to see it working: which driver or harness, which user actions, and what the user would observe on success. Find out what already exists first: a project verification skill (often named `verify-<app>`), an end-to-end suite, a driver or harness in the repo, a documented way to launch the app.

Where nothing can drive the behavior, plan the means to do it as part of this feature or fix, with code sketches like any other task: the harness or driver setup, how the app is launched in a controllable state, and one scenario that proves the harness works. Schedule it before the tasks it verifies, because every later task benefits from it. Prefer a reusable harness that lives in the repo over a one-off script, so the next change can use it too.

Some things cannot be driven by an agent: behavior that depends on a production-only service, physical hardware, or an account the session must not use. Verify everything around the gap, record the gap and the reason in the task file, and tell the user which part they need to check themselves.

Slice the work into tasks that are each one verifiable unit: a coder can finish it, run a check, and you can review it alone. Order them so foundations (data shapes, shared types, the verification harness) come first. Note which tasks depend on which.

Tell the user the plan in a few lines and proceed. Ask first only when a decision is theirs to make and changes what gets built.

### 2. Decide where the work happens

If the user said where (a branch name, "on main", a worktree), do that. Otherwise decide:

- **Feature or fix branch** off the default branch is the default. Follow the repo's branch naming if it has one; otherwise `feat/<slug>` or `fix/<slug>`.
- **Git worktree** when the current checkout holds uncommitted work unrelated to this task, or when tasks run in parallel.
- **Parallel tasks** only when they touch disjoint files and neither needs the other's result. Give each parallel coder its own worktree (the Agent tool's `isolation: "worktree"`) so two writers never share a working tree, and merge each into the integration branch after its review passes.

Look at `git status` before creating anything. Uncommitted changes that are not yours belong to the user: do not stash, reset, or commit them. Use a worktree, or ask.

### 3. Create the task file

Create it before the first coder is spawned. Put it in the session scratchpad directory if the environment provides one, otherwise the OS temp directory, named `orchestrate-<slug>-<YYYYMMDD>.md`. Keep it outside the repository so no `git add` picks it up and every worktree sees the same file. Tell the user its absolute path.

If a task file for this work already exists, read it and continue from it.

Use this structure:

````markdown
# Orchestration: <title>

- **Goal:** <one or two sentences>
- **Where:** <branch / worktree path(s)>, base `<base branch>`
- **Started:** <date>
- **PR:** <link, once opened>

## Verification plan
- <behavior> — driven with <driver/harness>: <user actions> → <what the user should observe>
- Harness to build: <what, as task Tn> (or "none needed")
- Cannot be verified by an agent: <what and why> (or "nothing")

## Tasks
- [ ] T1 — <task> · complexity: low|medium|complex · coder: <model>, <agent id>
- [ ] T2 — <task> · depends on T1 · ...

## Review findings
### T1, round 1
- [ ] R1 · must-fix · `path/file.go:42` — <what is wrong and what correct looks like>
- [ ] R2 · should-fix · `path/file.go:88` — <...>

## Deferred
- R2 (T1) — <what>, why deferred, suggested follow-up (separate PR / issue)

## Decisions
- <date/time> — <decision> — <why>

## Verification
- <build/test command> → <result>
- <scenario driven in the real app> → <what was observed>
- Not verified: <what and why>
````

Tick a task only when its review is approved and its behavior has been seen working in the driven application. Tick a finding only after you have re-checked the fix yourself. Record under Decisions: where the work happens, model choice for anything not obvious, parallelization, every deviation from the plan you accepted, every deferral, and any escalation.

### 4. Delegate

**Choose the model by the complexity of the task as briefed**, not of the overall project:

| Complexity | Agent `model` | Agent `effort` | Typical signs |
|---|---|---|---|
| Low or medium | `haiku` (Haiku 5.5) | `xhigh` | The sketch pins down data shapes and control flow; few files; follows a pattern already in the codebase |
| Complex | `sonnet` (Sonnet 5.5) | `high` | Concurrency or shared state, subtle invariants, cross-cutting refactors, security-sensitive logic, or design decisions the sketch cannot fully settle |

A good sketch lowers complexity. If a complex task splits along a natural seam into medium ones, split it; do not split just to reach a cheaper model.

**Write the brief.** Subagents start cold: they have none of your conversation, your reading, or the user's words. Everything they need is in the brief. Use this shape:

````markdown
## Goal
<what this task achieves and why it matters to the larger change>

## Scope
- Files to create/change: <paths>
- Out of scope, do not touch: <paths / areas>

## Where to work
<repo path or worktree, branch; commit rule from below>

## Code sketches
<see below>

## Tests to write first
<test names, what each asserts, where they live>

## Verify
<exact commands for build, tests, lint, and what passing looks like; environment quirks>
<how to launch and drive the real application for this task: the driver or harness, the
user actions to perform, and what should be observed. Do this before reporting, and
report what you saw. If a scenario cannot be driven, say so instead of skipping it.>

## If the sketch does not fit reality
Small deviations: make them and list them in your report with the reason.
A deviation that changes a data shape, a public signature, or the behavior described here: stop and report instead of improvising.

## Report back
Summary · files changed · tests run and their results · scenarios driven in the real
application and what you observed · anything you could not verify and why ·
deviations from the sketch · any TDD escape with its concrete reason · open questions ·
your action log.

<contents of references/coding-standards.md, verbatim>
````

**Code sketches are required in every coding brief.** Their purpose is that the coder implements your design instead of inventing one, so the result behaves as planned and review is a comparison rather than a discovery. A sketch contains, in the project's language and with its real identifiers:

- the data shapes and types, first
- the signatures of the functions and methods to add or change
- the control flow of anything not obvious, including error handling at boundaries
- a pointer to the existing code to imitate (`path:line`)
- the test cases to write before the implementation

Say which parts are binding (types, signatures, observable behavior) and which are illustrative (function bodies). Stop short of a full implementation: that would be you coding, and it leaves the coder nothing to verify against the real code.

**Commit rule to put in the brief.** In the shared checkout, the coder leaves its changes uncommitted; you commit each task after you approve it, so history holds only reviewed work. In its own worktree, the coder commits to its worktree branch before reporting, so nothing is lost when the worktree is cleaned up and you have a branch to review and merge. Coders never push.

Spawn the coder with the Agent tool (`subagent_type: "general-purpose"`, plus the `model` and `effort` above) and record its agent id next to the task. Subagents may run in the background: wait for the completion notification, do not poll, and never guess at a result. While one works, you can prepare the next sketch.

### 5. Review

Review the diff, not the coder's report. The report tells you where to look and what was skipped; the code tells you what was done.

1. Read the full diff for the task.
2. Run the build, tests, and linters yourself.
3. Drive the real application through the task's scenarios from the verification plan and watch the behavior yourself. The coder's account of having done so is a claim, not evidence. Running a driver or harness is not coding; if a scenario needs new harness code, that goes to a coder.
4. Compare against the brief: is the sketch's binding part implemented, and is each reported deviation justified?
5. Check the standards, especially TDD: do the new tests exercise behavior the way a caller would, and would they fail without the change?

Report only two kinds of finding:

- **must-fix** — the change is wrong or unsafe to build on: incorrect behavior, a broken contract from the plan, failing build or tests, a scenario that does not work when driven in the real application, data loss or a security hole, a behavior change with no test and no accepted justification, or a root cause hidden behind a guard.
- **should-fix** — it works, but leaves a real cost a careful maintainer would insist on removing: one decision living in two places, a plausible edge case unhandled, a test that pins implementation instead of behavior, a misleading name on a public surface.

Leave everything else alone. Style preferences, naming taste, equally good alternative approaches, and anything a formatter handles are not findings. Each round costs a full coder turn, and nit-picks bury the findings that matter.

Write every finding into the task file with an id, severity, `file:line`, what is wrong, and what correct looks like.

**Deciding on should-fix items.** Fix now when the fix is small and inside code this change already touches. Defer to a later PR when it widens the scope, touches unrelated code, or needs a design decision of its own. Record each deferral under Deferred with the reason. Must-fix items are never deferred; if one cannot be fixed, stop and tell the user.

### 6. Fix loop

Send the findings to the coder that wrote the code, by continuing that agent (SendMessage with its agent id), because it already holds the context. If it is no longer reachable, spawn a new coder with the original brief, a description of the current state, and the findings. A fix message lists each finding by id and says to fix those and nothing else.

When the coder reports back, review again: check each fix yourself, rerun the tests, and look at whether the fix disturbed anything nearby. New findings start a new round in the task file. Repeat until no must-fix is open and every should-fix is either fixed or deferred with a recorded decision. Then tick the task and commit or merge it.

If the same finding survives two rounds, more rounds will not help. Name the assumption that keeps failing: usually the sketch was wrong or underspecified, or the task was harder than you rated it. Rewrite the sketch, re-slice the task, or move it to Sonnet, and record which and why.

### 7. Integrate and verify

After the last task is approved, and after every merge of a parallel worktree, run the full build and test suite on the integration branch. Then drive the application through the whole verification plan end to end, as a user would, including a pass over nearby behavior the change could have disturbed. Tasks that each worked alone can still fail together. Record the commands, the scenarios, and what you observed under Verification. A failure here is a must-fix: write it down and send it to a coder.

Anything that was not verified is listed under "Not verified" with the reason. Do not describe unverified work as working.

Remove worktrees you created once their branches are merged. Leave anything with unmerged or uncommitted work and mention it in the report.

### 8. Raise the PR

Unless the user asked for something else, push the branch and open a pull request with `gh pr create`. The body states what changed and why, how it was verified in the running application, what could not be verified, and lists the deferred items so they are not lost. Put the PR link in the task file.

If the user asked for the work on the main branch, commit there and do not open a PR; push only if they asked for that.

### 9. Report

End the session by showing the user the task file's full contents in your final message, along with the PR link. Paste the contents; a path into a temp directory may not be openable later. The user should be able to see from that one message what was done, how it was verified, what was found in review and how it was resolved, and what was deferred and why. If any behavior could not be verified by driving the application, say so in its own line outside the pasted file, with what the user needs to check themselves.
