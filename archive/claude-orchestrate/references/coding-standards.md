## Coding standards

Include these standards in every coding-agent brief (require adherence). Structure work as: **First make it work → Then make it right → Follow practice.**

### First make it work

**Laziness protocol**

- One decision lives in one place.
- Ship the smallest edit that solves the problem — within a design that can hold the requirement (see Redesign precedence below).

**Foundational thinking**

- Get the data shape right before you write the logic.
- Do first whatever helps every later phase.
- If a concurrent writer would matter, do not share mutable state.

**TDD**

- When adding or changing behavior: write the failing test before you change the code.
- See it fail for the reason you expect.
- Make the smallest change that makes it pass.
- Escape hatch: skip only when a contract-level test is genuinely impractical. Note the concrete reason in the brief and the action log (what you would have tested, why it is not feasible). Reviewers treat unjustified skips on behavior-changing slices as `must-fix`. Accept the escape only when the brief or action log shows why a contract-level test was not feasible.

**Redesign from first principles**

- Do not bolt a new requirement onto the old design.
- Ask what you would have built if it had been there from the start, think that through, and deliver it in pieces.
- **Precedence vs laziness:** Prefer the smallest edit *within* a design that can hold the requirement. If the current design cannot hold it, redesign-in-slices wins over bolting the requirement onto the old shape.

**Attack the premise**

When two or more fixes fail the same gate because they share one assumption:

1. Name the failing shared assumption in one sentence.
2. Stop stacking more fixes on that assumption.
3. Change the design or ownership that makes the gate fail.
4. Re-test against the same gate before continuing.

**Subtract before you add**

- Take complexity out before you add anything.

**Outcome-oriented execution**

- Aim at the end state you can check.
- A break in the middle is allowed when you planned it and can undo it.

**Build the lever**

- If the work is not obvious at a glance, build the tool that does it.
- Do one unit by hand, then make the tool match that unit.

**Architecture**

Model the domain:

- Put the domain in a structure that makes illegal states impossible.
- Maintain a glossary of domain terms when introducing new ones.
- If the code is already clear and local, leave it.

Boundary discipline:

- Check the data where it enters.
- Inside, trust it.
- Keep business logic in a pure function when practical.

Type system discipline:

- Make the illegal value impossible to write.
- Parse outside data once, where it comes in.
- Do not silence the compiler.

Make operations idempotent:

- Running twice, or running after a crash halfway through, ends in the same state.

Separate before serializing shared state:

- If they do not need the same mutable thing, give each its own.
- If they do, allow one writer, and enforce that in the structure.

### Then make it right

**Fix root causes**

- Reproduce it.
- Fix the cause.
- A guard that only hides the crash is not a fix.

**Sequence work into verifiable units**

- Finish one small unit and check it.
- Then start the next.

**Test behavior, not implementation**

- The test calls the code the way its user does and checks the result that user would see.
- If the test would still pass when every function returned nothing, throw it out.

**Refactoring**

- Pin what the code does.
- Change the structure.
- Prove the behavior did not change.

### Practice

**Keep a log**

- Keep a short log of every action and why.
- Report that log in the agent return summary upon completion.

**Guard the context window**

- Keep the main thread small.
- Send the bulk elsewhere; keep the summary.

**Worktree cleanup**

- When you create temp artifacts: find what is safe to remove, confirm nothing still in use needs it, then reclaim the disk.
- Uncommitted work waits for a decision.
- Do not invent git branch rules that conflict with the environment.
