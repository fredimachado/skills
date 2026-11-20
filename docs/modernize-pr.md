# modernize-pr

Brings an old pull request up to date, and first asks whether it should still exist.

Skill file: [skills/modernize-pr/SKILL.md](../skills/modernize-pr/SKILL.md). Back to the
[overview](../README.md).

## What it solves

A pull request that sat for months is stale in two ways. The branch is behind, which a
rebase fixes. The idea may be stale too, and a rebase says nothing about that. Maybe
someone solved the same problem another way. Maybe the code it changes was deleted on
purpose. A rebase with no conflicts only shows the text still applies.

`modernize-pr` reads what the pull request was for and what happened around it, then
gives a verdict before it touches the branch.

## How it works

1. **Read what the pull request was for.** Title, description, linked issues, commits,
   review threads, the whole diff. It writes the goal as one sentence.
2. **Read what changed on the base branch since.** Was the problem already solved? Did the
   APIs it relies on change? Would landing it bring back old behavior, or leave two ways
   to do one thing?
3. **Decide.**
   - **MODERNIZE.** The goal is still useful and the approach still fits. Go on to the
     rebase.
   - **REWORK.** The goal is still useful, but the approach no longer fits. It describes
     the smallest rewrite and stops.
   - **CLOSE.** The pull request was replaced or is no longer worth its cost. It gives the
     evidence and stops.
4. **Rebase,** for MODERNIZE only. It resolves conflicts by what the pull request is for,
   compares the commits before and after, runs the checks and pushes. The push is pinned
   to the old commit, so it fails if someone else pushed in the meantime.
5. **Report.** The verdict and its reason first, then what is left for you to decide.

It never merges, closes, changes the base branch or posts a comment. Age alone is not a
reason to close, and work already spent is not a reason to keep.

## How it connects

It runs on its own. Three neighbors are worth knowing:

- [babysit-pr](babysit-pr.md) handles a pull request that is only a few commits behind.
  This skill is for one that is months behind.
- [orchestrate](orchestrate.md) treats a merge conflict as code. When this skill runs
  under it, a coder resolves the conflict.
- [csharp-modernization](csharp-modernization.md) has a similar name and a different job.
  It updates code to newer language features. This skill updates a pull request.

## How to ask for it

"Is this old pull request still worth merging?", or "rebase and refresh this stale
branch".
