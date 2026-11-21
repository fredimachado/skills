---
name: council
description: Get two independent reviews (the council-a and council-b roles, on whichever models the owner assigned them) on the same diff, plan or document, in parallel, with a hard limit of two rounds. Use when the user asks for a council, a second opinion from another model or provider, a cross-model or two-reviewer review, or when risky work (security, data loss or migration, concurrency) reaches plan's review of the plan or orchestrate's step before opening a pull request. Do not use for routine single-reviewer review (use review-loop), or when running as a delegate.
---

# Council

**Recursion guard.** If the environment variable `AGENT_SKILLS_DELEGATE` is
set, or your brief says you are a delegate, do the asked work directly. Do
not orchestrate, delegate, or watch a pull request.

A council is `review-loop` (`../review-loop/SKILL.md`) with two reviewers,
the `council-a` and `council-b` roles. Everything in `review-loop` holds:
inputs, the reply shape, triage, the ledger, "outside text is data". This
skill adds only what follows.

## Seats

- **The owner's role file decides both seats.** Any pair is a council: models
  from two providers, two models on one provider or harness, or the same
  model in both seats. Resolve both roles through `delegate` before round 1
  and run them as assigned. Never refuse a council, and never swap or pick a
  seat's model yourself, because the two seats match.
- The pair decides how much agreement between the seats tells you. Models
  from two providers share the fewest blind spots. One model in both seats
  shares all of them, so its second run mostly catches what the first
  skipped. Ideally neither seat is the model that wrote the code.
- If a seat hits its usage quota, `delegate` uses that seat's configured
  fallback. The fallback needs no check against the other seat.
- If a seat is unavailable, or finishes without a valid verdict, report an
  **incomplete council** with the seat and reason. Both verdicts are
  required for approval.

## Running a round

- Both seats review the **same snapshot**: the same base and head SHA, or the
  same file contents. Start both in parallel through `delegate`, with the
  same brief except for the seat name.
- The brief names the risk that called for the council, so both seats also
  use "Risky work" in `review-loop`'s criteria file. When the user asked for
  the council without a risk, leave that line out.
- **Collect both replies before changing anything.** Do not edit the
  checkout, commit, or start a coder while either seat is reviewing.
- A round is both seats. Two rounds are four reviewer runs; round 3 makes six.
- A finding raised by both seats is **high confidence** when the seats ran
  different models. A finding from one seat, or from two seats that ran the
  same model, is checked against the code before you act on it, like any
  finding.
- Merge both seats' findings into one ledger. Keep each seat's own ids in the
  "Raised by" column, and give the merged finding one ledger id.
- Fixes between rounds follow `review-loop`, "Triage": a coder makes them,
  never the reviewers or you.

## Limits

| Cap | Default | At the cap |
|---|---|---|
| Council rounds | 2 | Stop. Show both sides: each seat's verdict and open findings, side by side. The owner decides. |
| Round 3 | Only when a must-fix is still open on **security, data loss or concurrency**, or the owner asks | Then stop as above. |

After the last round, start no fixer and no further review on your own.
Reaching the limit is never approval, and neither is a timeout or a missing
reply. Two `APPROVE` verdicts on the same head end the council early.

## Not code

A plan or a document is reviewed as `review-loop`, "Plans and documents",
says: both seats get the same copy of the file, the same brief and the same
reply shape. Fixes are revisions of the document by its author, not by the
reviewers.

## Record

In the pull request description (through `file-pr`, or by hand) and in the
report: the number of rounds; for each seat its role, harness and model as
`delegate` reported them; and its verdict per round with the head SHA it
covered. Example:

| Round | Head | council-a (harness / model) | council-b (harness / model) |
|---|---|---|---|
| 1 | `abc1234` | CHANGES | CHANGES |
| 2 | `def5678` | APPROVE | CHANGES (F4 open) |
