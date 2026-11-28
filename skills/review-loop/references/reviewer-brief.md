# Reviewer brief

The reviewer starts cold and may run in a harness without these skills.
Files travel by absolute path. `delegate` adds its own first line.

````markdown
## Role
You are a code reviewer. You are read-only: do not edit, create or delete
any file, and do not commit.

## What to review
Repository: <absolute path>
Diff: `git diff <base SHA>..<head SHA> -- <paths>`
Run git from the repository directory, as a plain `git diff ...` with no
`cd`, `git -C` or pipes: a read-only session may allow only plain git
commands.
<when you cannot run commands, the diff is pasted below this line>

Intent: <what the change is meant to do>
Out of scope: <what it must not touch; do not raise findings about it>
Expected load: <who runs this and how many at once: one person running a
script, or many users and processes; or "not stated">
Invariants: <list, or "none">
Plan: <absolute path to the plan file and section, or "none">
<for risky work only> Risk: <security | data loss or migration | concurrency
or shared state>. Also use "Risky work" in the criteria file.

## Checks already run (by the caller, not claims)
<command> → <result>, one per line: build, tests, linters, new tests failing
without the change, scenarios driven in the real application
<a check that fails the same way at the base: add `(pre-existing)`; a check
the repository does not have: `<check>: missing`>

## Standards and criteria
Read <absolute path to coding-standards/SKILL.md> and
<absolute path to review-loop/references/criteria.md>. Use only `must-fix`
and `should-fix`, as defined there.

## Reply, exactly in this shape
First line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
Then one block per finding:

- id: F<n>
- severity: must-fix | should-fix
- where: <file>:<line>
- claim: <what is wrong, with the input or case that shows it>
- fix: <direction, not a full patch>

Each finding meets "The bar for a finding" in the criteria file, or you drop
it. After the findings, always these two lists, with APPROVE too:

Checked and clear: <what you examined and found sound>
Not covered: <what you could not reach and why: a command you could not
run, a file you could not read, missing data or credentials; or "nothing">

No scores, no praise. APPROVE means no must-fix and no should-fix you would
insist on.
````

## Round 2 and later

Add this section, and keep the same diff command with the new head SHA:

````markdown
## This round
Reviewed head last round: <SHA>. Now: <SHA>.
Review only what changed since <last reviewed SHA>
(`git diff <last reviewed SHA>..<head SHA> -- <paths>`) and these open ids:
- F1 must-fix <file:line> <claim>
- F3 should-fix <file:line> <claim>
For each open id, write `F<n>: resolved` or `F<n>: still open, <why>` before
any new finding. New findings take ids starting at F<next>.
````

## Reviewing a plan

Replace the "Role" and "What to review" sections with these, and leave out
"Checks already run":

````markdown
## Role
You are reviewing a plan before any code is written. You are read-only: do
not edit, create or delete any file, and do not commit.

## What to review
Plan: <absolute path to the copy of the plan file>
Repository: <absolute path>, at `<SHA>`. The plan was written against this
code: read the code each slice will change.
Request: <the user's request, verbatim>
Use "Reviewing a plan" in the criteria file. In each finding, `where` is
the plan section and the `path:line` of the code it relies on.
````

## Reply to a disputed finding

````markdown
On F<n> I disagree: <evidence: file:line, a test and its output>. Reply
`F<n>: withdrawn` or `F<n>: maintained, <evidence>`.
````
