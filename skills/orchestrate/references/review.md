# Review

Review is `review-loop` (`../../review-loop/SKILL.md`) with one reviewer, the
`reviewer` role. Before you call it, gather the evidence it takes as input.
The reviewer reads the diff; these checks are yours.

## Before review

Run these yourself, on the commit you will send for review: `git status` is
clean and `HEAD` is that SHA. If the checkout has uncommitted changes, or a
coder is still working in it, use a clean worktree at that SHA. Otherwise you
test someone's edits, not the commit. Record the commands, the results and
the SHA in the task file:

1. The build, the tests and the linters that CI runs. Read the workflow for
   the commands and the operating systems. A system CI covers that you could
   not run goes under Not verified.
2. **New tests fail without the change.** In a temporary worktree at the
   head, put the non-test files the task touched back to the base
   (`git checkout <base> -- <changed paths>`, and `git rm` the ones it
   added), run the new tests, see them fail for the expected reason, then
   remove that worktree. This is running git, not coding.
3. Drive the real application through the task's scenarios from the
   verification plan and watch the behavior. The coder's account of having
   done so is a claim, not evidence. If a scenario needs new harness code,
   that goes to a coder.

A failure in any of these is a must-fix you record yourself, with an id in
the ledger, and the coder fixes it before the reviewer runs. Review rounds
are capped: a round spent on code you know is broken tells you what you
already knew. A check that fails the same way at the base is not this
change's failure. Record it as pre-existing and say so in the reviewer's
brief.

## Calling review-loop

Pass: base SHA and head SHA of the task, its paths, the intent from the
plan, what is out of scope, the invariants, the results above, the plan file
path, `reviewer` as the one reviewer role, and the task's remaining round
budget. The ledger is the task file's. Read the diff yourself as well,
against the brief: is the sketch's binding part implemented, and is each
reported deviation justified? Your findings go in the same ledger.

If the `reviewer` role is unavailable on this host, the review is not done:
tell the owner and stop that task. Your own reading does not replace the
reviewer.

Every verdict names the base SHA and head SHA it covers, in the Rounds table.
