# council

Gets two independent reviews of the same change, from models made by different providers,
and stops after two rounds.

Skill file: [skills/council/SKILL.md](../skills/council/SKILL.md). Back to the
[overview](../README.md).

## What it solves

Every model has blind spots, and a reviewer from the same family as the author often
shares them. For most changes one reviewer is enough. For risky ones it is thin: security,
data loss, migrations, concurrency.

Two models from different providers miss different things. When both raise the same
problem, it is probably real. When they disagree, you see both sides instead of one
confident answer.

## How it works

1. **Check the seats.** The two reviewers are the roles `council-a` and `council-b`. They
   must come from different providers. If they do not, or one is unavailable, the skill
   says so and stops. One reviewer is not a council, and nothing is substituted.
2. **Review the same snapshot in parallel.** Both get the same commits and the same brief.
   Nothing is edited while either is still reading.
3. **Merge the findings into one list.** A finding raised by both seats is high
   confidence. A finding from one seat is checked against the code like any other.
4. **Fix between rounds.** A coder makes the fixes, never a reviewer.
5. **Stop at two rounds.** A third round happens only if a must-fix on security, data loss
   or concurrency is still open, or you ask for one. At the limit the skill shows each
   seat's verdict and open findings side by side, and you decide.

Two approvals on the same commit end the council early. Reaching the limit is never
approval.

## How it connects

- [review-loop](review-loop.md) is the base. A council follows all its rules for replies,
  triage and the list of findings, and adds the second reviewer.
- [delegate](delegate.md) starts both seats.
- [orchestrate](orchestrate.md) calls it once on the finished change, before the pull
  request, when the work is risky.
- [plan](plan.md) calls it instead of a single reviewer when the plan is for risky work.
- [file-pr](file-pr.md) writes the council's record into the pull request description.

## How to ask for it

"Get a council on this diff", or "I want a second opinion from another provider".
