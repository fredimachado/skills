# review-loop

Has a separate agent review a change, checks each thing it finds, gets the real problems
fixed, and stops after a fixed number of rounds.

Skill file: [skills/review-loop/SKILL.md](../skills/review-loop/SKILL.md). Back to the
[overview](../README.md).

## What it solves

Review between agents goes wrong in a few known ways. The loop never ends, because every
round finds something new to polish. Findings are applied without anyone checking they
are true, so the change grows with each round. A finding is raised, then lost. A reviewer
that timed out is read as "no objections".

`review-loop` sets a budget, makes the caller check every finding against the code, keeps
a list of findings that survives the whole loop, and never treats silence as approval.

## How it works

1. **Collect the inputs.** The exact range of commits, what the change is meant to do,
   what it must not touch, and the results of the checks the caller already ran.
2. **Start a reviewer.** It only reads. It is a fresh agent that has seen none of the
   conversation, and where possible a different model from the one that wrote the code.
   A confirmed usage cap can switch the role to its configured fallback.
   The caller never does the reviewer's part itself.
3. **Read the reply.** The first line is `VERDICT: APPROVE` or `VERDICT: CHANGES`. Each
   finding has an id, a severity, a file and line, a claim and a direction for the fix.
   The reviewer also lists what it checked and what it did not cover.
4. **Triage every finding.** The caller checks each one against the code and picks one of
   three answers:
   - Agree. A coder makes the smallest fix.
   - Disagree. Reply with evidence. After two replies on the same finding, you decide.
   - Out of scope. Decline it in one line and list it as a follow-up.
5. **Run more rounds only when needed.** Later rounds look at what changed since the last
   one and at the findings still open. The default budget is three rounds.
6. **Report.** The final verdict, the rounds used, and the full list of findings with what
   happened to each.

There are two severities. A `must-fix` blocks the change. A `should-fix` can be deferred
with a reason. If the budget runs out with a must-fix open, the change is not ready.
Reaching the cap is never approval.

The same loop also reviews a plan or a document before anything is built from it.

## How it connects

- [delegate](delegate.md) starts the reviewers, and the coders that make the fixes.
- [coding-standards](coding-standards.md) is handed to each reviewer as the bar to review
  against.
- [orchestrate](orchestrate.md) calls it after each coding task.
- [plan](plan.md) calls it to review a plan against the code.
- [council](council.md) is this same loop with two reviewers instead of one.
- [babysit-pr](babysit-pr.md) reuses its triage rules for comments on a pull request.

## How to ask for it

"Have a reviewer agent review this branch", or "run a review-and-fix loop on this diff".
