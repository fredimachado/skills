# file-pr

Opens a pull request that starts with the problem, says how the change was verified, and
admits what was not.

Skill file: [skills/file-pr/SKILL.md](../skills/file-pr/SKILL.md). Back to the
[overview](../README.md).

## What it solves

Agents write pull request descriptions as an inventory: "removed this, added that, moved
the other". A reviewer learns which lines changed, which the diff already shows, and
nothing about why. Other common failures are pushing a commit nobody reviewed, leaving a
stray file or a secret in the diff, and claiming everything was tested.

`file-pr` checks the change before it leaves the machine and writes a description a
person can review from.

## How it works

1. **Check before filing.** Is there already a pull request for this branch? Does the diff
   contain only the intended change, with no stray files, debug output or secrets? Is the
   commit being pushed the one that was reviewed and verified?
2. **Write the title.** Short, in the repository's style, about why the change matters and
   not which mechanism changed.
3. **Write the description in this order:**
   - the problem, in plain words
   - the solution, briefly
   - how it was verified in the running application
   - what was not verified, and why
   - findings that were deferred, each with its reason
   - the review and the council, when they ran
   - which models and tools made the change
4. **Follow the repository's template** when it has one. The template's sections win.
5. **Read it once more for secrets and private details,** including quoted logs and
   screenshots.
6. **Open a real pull request,** not a draft, so review bots run.

The "what was not verified" line is never dropped. It says "nothing" only when that is
true.

## How it connects

- [orchestrate](orchestrate.md) calls it when the work is reviewed and verified.
- [council](council.md) supplies the record of its rounds for the description.
- [delegate](delegate.md) recorded which model did each part. The attribution uses that.
- [babysit-pr](babysit-pr.md) takes over after the pull request opens, if you asked for it
  to be watched.

You can use it on its own for any branch you want filed.

## How to ask for it

"Open a pull request for this branch."
