# plan

Gets one plan for a coding task, detailed enough that a coder can build it without
inventing the design, and checks it before any code is written.

Skill file: [skills/plan/SKILL.md](../skills/plan/SKILL.md). Back to the
[overview](../README.md).

## What it solves

Hand a coder a vague task and it makes up the design as it goes. Two coders make up two
designs. A plan full of lines like "handle edge cases" decides nothing, and a plan can
confidently describe functions that do not exist.

`plan` produces a plan with code sketches: the data shapes, the function signatures, the
tests to write first. Then it checks the plan twice, once for completeness and once
against the real code.

## How it works

1. **Decide whether a plan is needed.** A plan file is worth it when the work is complex
   and the details are thin. A simple change, or one that already has a clear design,
   skips it.
2. **Run the planner.** One read-only run of the `planner` role. If the planner is not
   available after any configured usage-quota fallback, the skill stops and tells you.
   It uses only the primary or fallback you configured for the planner role.
3. **Save the plan** outside the repository and give you its path.
4. **The plan holds** the problem, acceptance criteria that can be checked, what to delete
   before adding anything, and the work cut into slices. Each slice lists its data shapes,
   signatures, what else it must reach (the callers, tests and fixtures that use what it
   changes), the tests to write first, a place in the existing code to imitate, and how
   the result will be seen working in the real application.
5. **Gate.** The caller runs a checklist. Can each criterion be checked? Is every hard
   problem addressed instead of postponed? Does every file and function the plan names
   exist? That last one is checked by searching the repository, not from memory.
6. **Revise once.** A failed gate goes back to the same planner one time. If it fails
   again, the skill stops and shows you the gaps. No coding starts.
7. **Review against the code.** The gate shows the plan is complete. It does not show the
   plan is right. A reviewer reads the plan next to the code and reports what does not
   hold.

## How it connects

- [delegate](delegate.md) runs the planner and the reviewer.
- [review-loop](review-loop.md) runs the review of the plan in step 7.
- [council](council.md) replaces the single reviewer when the work is risky.
- [coding-standards](coding-standards.md) is what the code sketches follow.
- [orchestrate](orchestrate.md) calls `plan` as its first step. You can also use `plan` on
  its own when you only want the plan.

## How to ask for it

"Write an implementation plan for this feature", or "make this spec executable".
