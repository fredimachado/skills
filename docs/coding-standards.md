# coding-standards

One file that says how code should be written and reviewed. Every coder and reviewer gets
the same one.

Skill file: [skills/coding-standards/SKILL.md](../skills/coding-standards/SKILL.md). Back
to the [overview](../README.md).

## What it solves

Each agent arrives with its own idea of good code. One adds a guard to hide a crash,
another writes the test after the code, a third bolts a new requirement onto a design that
cannot hold it. Reviews then argue about taste.

Pasting the rules into every skill does not fix this, because the copies drift apart.
This skill is the single copy. Other skills pass its file path to the agents they start,
so the planner, the coder and the reviewer all work from the same text.

## How it works

The standards come in three parts.

**First make it work.**

- Make the smallest edit that solves the problem, inside a design that can hold the
  requirement. If the design cannot hold it, redesign in slices.
- Get the data shape right before writing the logic.
- Write the failing test first, and see it fail for the reason you expect.
- Take complexity out before adding anything.
- When two fixes fail for the same reason, stop adding fixes and question the assumption
  they share.
- Check data where it enters the program. Inside, trust it.

**Then make it right.**

- Reproduce a bug and fix its cause. A guard that hides the crash is not a fix.
- A test that fails only sometimes is a bug.
- Test what the user of the code would see, not how the code is built inside.
- To refactor, pin the behavior, change the structure, then prove the behavior did not
  change.
- A comment says what the code cannot. It does not narrate the change.

**Practice.**

- Keep a short log of each action and why.
- Commit in small steps. Each message says why, what changed and how it was proven.
- A coding agent never pushes and never opens a pull request.

Used on its own, the skill reviews code or a plan against these headings and reports each
problem with its file and line. It skips anything a formatter would settle.

## How it connects

- [orchestrate](orchestrate.md) reads it before planning and gives its path to every
  coder.
- [plan](plan.md) writes code sketches that follow it.
- [review-loop](review-loop.md) hands it to reviewers as the bar to review against.
- [delegate](delegate.md) puts its absolute path in every brief, because a helper agent
  may not have this skill installed.

## How to ask for it

"Review this against my coding standards."
