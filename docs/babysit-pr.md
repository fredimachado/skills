# babysit-pr

Watches your pull request through CI and review, deals with what comes in, and tells you
when it is ready, waiting for a person, or blocked. It never merges.

Skill file: [skills/babysit-pr/SKILL.md](../skills/babysit-pr/SKILL.md). Back to the
[overview](../README.md).

## What it solves

Opening the pull request is not the end. Checks take minutes, review bots comment, the
base branch moves. An agent left alone here tends to do one of four things: poll in a
loop that burns its budget, stop and forget, apply every bot comment without thinking, or
merge.

`babysit-pr` waits with one watcher script instead of a loop, judges each comment before
acting, keeps the pull request from growing, and leaves merging to you.

## How it works

1. **Check the setup.** The GitHub CLI must be installed and signed in. It also checks
   whether the pull request is set to merge automatically. If it is, a push that turns the
   checks green would merge it, so the skill stops and asks you.
2. **Wait with the watcher.** The script `pr-wait.ps1` (Windows) or `pr-wait.sh` (Linux
   and macOS) prints one line per real event and exits when the pull request is ready or
   needs action. It remembers what it already reported.
3. **Judge what arrives.** Each failed check and each comment is checked against the code.
   A real bug gets fixed. A wrong claim gets a drafted reply with evidence. Anything
   outside the goal is declined and listed as a follow-up. A test that fails only
   sometimes counts as a bug, and is never rerun until it passes.
4. **Fix and push in batches.** Coders make the fixes. Each fix is proven before the
   push. There is one push per cycle, because every push reruns CI. After three cycles it
   stops and reports.
5. **Handle a moving base branch.** If the branch is behind, it brings the base in.
   Conflicts go to a coder, and the result is compared with what was reviewed before.
6. **Hand off.** It reads the live pull request once more and reports one of three states:
   ready to merge, waiting for human approval, or blocked.

It never posts, replies to or resolves a comment without your say. Drafted replies go in
its report.

## How it connects

- [file-pr](file-pr.md) opens the pull request that this skill then watches.
- [orchestrate](orchestrate.md) continues with it when you chose the `merge-ready` finish.
- [review-loop](review-loop.md) supplies the rules for judging findings, and reviews any
  fix that changes behavior before it is pushed.
- [delegate](delegate.md) starts the coders that make the fixes and handles their
  configured usage-quota fallbacks.
- [modernize-pr](modernize-pr.md) is the skill for a pull request that is months behind,
  not a few commits.

## How to ask for it

"Watch this pull request until it is ready to merge."
