# orchestrate

Runs a whole coding task from plan to pull request. The session that runs it coordinates
and checks. Other agents write the code.

Skill file: [skills/orchestrate/SKILL.md](../skills/orchestrate/SKILL.md). Back to the
[overview](../README.md).

## What it solves

An agent that plans, codes and reviews in one session tends to approve its own work. It
also reports "done" when the tests pass, even if the feature does not work for a user. And
in a long session it forgets what was decided an hour ago.

`orchestrate` splits the jobs. One agent plans, others write the code, another reviews it.
The orchestrator never edits code, so its judgment of the code stays independent. It
writes everything into a task file, so nothing depends on memory. It accepts work only
after an agent has used the real application the way a user would.

## How it works

Four rules hold from start to finish:

- The orchestrator does not code. Even a one-line fix goes to a coder.
- The task file is the record. Every task, finding and decision goes there when it
  happens.
- The coding standards apply to the plan and to the coders.
- Work counts as verified only when someone drove the running application.

The steps:

1. **Plan.** It reads the code, then uses `plan` to get one plan with code sketches.
2. **Choose where to work.** Usually a feature branch, in a separate worktree when the
   checkout holds changes that are not its own.
3. **Take a baseline.** It runs the build, tests and linters before any change. A check
   that already fails is recorded, so nobody blames the new work for it. For a bug fix it
   reproduces the bug first.
4. **Delegate.** It picks one of four coder roles for each task, by signs it can check:
   `coder-mechanical` when the sketch is nearly the change itself, `coder-simple` when
   the sketch settles the design and the task follows an existing pattern,
   `coder-moderate` when the coder still makes local choices across several modules, and
   `coder-complex` for concurrency, migrations and other hard cases. In doubt it takes
   the higher role. You can give each role its own model, or fewer: see
   [delegate](delegate.md).
5. **Review.** It runs the checks itself, confirms the new tests fail without the change,
   drives the application, then calls `review-loop`.
6. **Fix.** Fixes go back to the coder that wrote the code. The loop has hard caps. If the
   same finding stays open for two rounds, it stops patching and rethinks the design
   or moves the task one coder role up.
   A coder's configured usage-quota fallback takes over its worktree and later fixes.
7. **Integrate and verify.** It merges the pieces, runs everything again and drives the
   application through the whole verification plan. Risky work gets a `council` here.
8. **Open the pull request.** Only a reviewed and verified head is pushed, through
   `file-pr`. The push is not finished until CI is green.
9. **Report.** It pastes the task file and lists what it could not verify and which
   decisions it took without you.

You choose how far it goes: `local` (nothing pushed), `open-for-review` (the default) or
`merge-ready`. It never merges.

## How it connects

`orchestrate` is the skill that ties the others together.

- [plan](plan.md) writes the plan in step 1.
- [delegate](delegate.md) starts every planner, coder and reviewer.
- [review-loop](review-loop.md) runs the review rounds in steps 5 and 6.
- [council](council.md) gives a second, independent review of risky work in step 7.
- [file-pr](file-pr.md) opens the pull request in step 8.
- [babysit-pr](babysit-pr.md) watches the pull request when you chose `merge-ready`.
- [coding-standards](coding-standards.md) is read before planning and handed to every
  coder.

It does not call [bootstrap-verification](bootstrap-verification.md), but a project that
has a `verify-<app>` skill from it gives the orchestrator a ready way to drive the
application.

If the orchestrator's own harness hits its usage cap, start a session in another
harness and point it at the existing task file to resume.

## How to ask for it

"Orchestrate this feature with coders", or "implement this plan with subagents, don't
write the code yourself".
