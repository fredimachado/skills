---
name: plan
description: Write one executable plan with code sketches for a coding task, using the owner's planner role, then check it against a gate and have a reviewer check it against the code before any coding starts. Use when the user asks for a plan, design or implementation plan for a feature, fix, refactor or migration, asks to make a spec or plan executable, or when another skill (such as orchestrate) needs a plan. Do not use for trivial edits, to get a second plan, or when running as a delegate.
---

# Plan

**Recursion guard.** If the environment variable `AGENT_SKILLS_DELEGATE` is
set, or your brief says you are a delegate, do the asked work directly. Do
not orchestrate, delegate, or watch a pull request.

One planner writes one plan, and a reviewer checks it against the code
before any coder starts. The plan carries code sketches that follow the
coding standards, so coders implement a design instead of inventing one.

**Skills this one uses:** `coding-standards` (`../coding-standards/SKILL.md`),
`delegate` (`../delegate/SKILL.md`), `review-loop`
(`../review-loop/SKILL.md`) and, for risky work, `council`
(`../council/SKILL.md`). Check they exist first.

## 1. Decide whether a plan file is needed

Write one when the work is complex **and** the detail is thin: acceptance
criteria, target shape or slice boundaries are missing or too vague to brief
a coder without inventing major design choices. Skip it when the request
already has a clear technical plan or an approved design, or the change is
simple and local; say so and stop. When the user asked for a plan by name,
write one.

- **Goal only:** produce the whole plan.
- **Existing plan or spec:** keep its decisions and add only what is missing
  to make it executable. If part of it looks wrong, tell the user instead of
  redesigning it silently.

## 2. Run the planner

The `planner` role, read-only, one run. First resolve the role the way
`delegate` says (role file, host override) and write down the harness and
model it names.

- **Plan inline only if both match:** the resolved harness is the one running
  this session, and the resolved model is the model you are running as. Same
  input, same output, same gate. If you cannot tell which model you are, or
  the role is empty, you are not the planner: do not plan inline.
- **Otherwise** run the `planner` role through `delegate`, read-only, with a
  brief built from `references/brief.md`. The brief carries the task, the
  repository path, the standards file path, the plan file path to write
  into the result, and the plan contents below. A planner reads the code
  before it writes and can take 10 to 30 minutes: keep the script's default
  timeout (do not pass a smaller `-TimeoutSec`), and give your own command
  limit more than that.
- If `delegate` reports the role unavailable, or the run fails or times out
  after its one retry, tell the owner and stop. **Never write the plan
  yourself in its place**: that is planning with another model.

Read-only planners cannot write files: the plan comes back as the
delegate's result, and you save it as the plan file.

## 3. Save the plan file

Outside the repository being changed, next to the caller's task file (or in
the session scratchpad or OS temp directory), named
`plan-<slug>-<YYYYMMDD>.md`. Give the user its absolute path. A caller with a
task file links it there.

## 4. What the plan file holds

1. The problem, and acceptance criteria that can be checked.
2. Whether the current design can hold the requirement. If not, the
   redesign, delivered in slices.
3. What is deleted or simplified before anything is added.
4. For each slice, in this order:
   - data shapes and types
   - signatures of functions to add or change
   - control flow that is not obvious, and parsing at boundaries
   - tests to write first: name, what each asserts, and why it fails before
     the change
   - invariants with one test each (stateful or migration work)
   - a `path:line` in the existing code to imitate
   - how the behavior will be seen working in the real application; for a
     fix, the reproduction that shows the failure today
   - for migrations, compatibility and recovery at each step
5. Slice order, dependencies, and which slices could run in parallel.
6. Risks, open decisions that could change the plan, and what is out of
   scope.

Sketches and slicing follow `references/sketches.md`.

## 5. Gate

Run by the caller, never by the planner. Accept the plan only if:

- the acceptance criteria can be checked
- slices are ordered and each can be verified on its own
- hard problems are addressed, not deferred
- there is one data shape and one ownership model
- every acceptance criterion is covered by a slice, and no line decides
  nothing ("handle edge cases", "TBD")
- no open decision that would change what gets built is left open. For each
  one the plan lists: a decision that is the owner's goes to the owner; a
  conventional default you may take yourself. Record every one with who
  decided it (owner, default, or you) and why. An answer that changes the
  plan goes to the planner with the gate's revision.
- every path and every symbol not marked **new** exists in the repository.
  Check each with a search (`git grep`, a file search), not by reading or
  from memory, and list what you searched.

Record the gate result line by line.

## 6. Revise once for the gate

| Cap | Default | At the cap |
|---|---|---|
| Gate revisions | 1 | Stop. Show the owner the plan and the gaps. No coding. |

On a failed gate, continue the **same** planner session (`delegate`,
"Follow-ups go to the same delegate") once, with the specific gaps by gate
line. Run the gate again. If it fails again, stop: no coder starts on a plan
that failed its gate. A timeout or an empty reply is never a passed gate.

## 7. Review against the code

The gate shows the plan is complete and names real code. It does not show
that what the plan says about that code is true, or that the approach holds.
Once the gate passes, run `review-loop` on the plan (`../review-loop/SKILL.md`,
"Plans and documents"):

- **Reviewer:** the `reviewer` role, one read-only run. For risky work
  (security, data loss or migration, concurrency or shared state), or when
  the user asks, `council` instead (`../council/SKILL.md`, "Not code").
- **Input:** a copy of the plan file, the repository path and SHA, the
  user's request verbatim, and the standards path.
- **Triage** every finding against the code, as `review-loop` says. Send the
  findings you agree with, by id, to the same planner session as one
  revision. A finding that turns on a decision that is the owner's goes to
  the owner, not to the planner.
- After the revision, run the gate again and check yourself that each
  finding you agreed with is closed.

| Cap | Default | At the cap |
|---|---|---|
| Plan review rounds | 1; `council` keeps its own limit | Start no further round on your own. |
| Revisions per review round | 1 | Must-fix still open: stop. Show the owner the plan and the open findings. No coding. |

If the reviewer is unavailable, or its run fails or times out after its one
retry, the plan is not reviewed: tell the owner and stop. A missing review
is never a passed review. Record the reviewer's role, harness and model, the
verdict and each finding with its outcome, in the caller's task file when
there is one.

## Files

- `references/sketches.md`: what a code sketch contains, how to mark it, and
  the default slicing.
- `references/brief.md`: the planner brief.
