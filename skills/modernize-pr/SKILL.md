---
name: modernize-pr
description: Bring an old pull request up to date and decide whether it should still exist. Reads what the pull request was for, checks what changed on its base branch since it branched, recommends MODERNIZE, REWORK or CLOSE, and only then rebases, runs the checks and pushes with a lease. Use when the user asks to rebase, update, refresh, revive or "modernize" an old or stale pull request or branch, or asks whether an old pull request is still worth merging. Never merges or closes. Do not use to move code to newer language features (use csharp-modernization), for a pull request that is only a few commits behind (babysit-pr handles that), or when running as a delegate.
---

# Modernize a pull request

**Recursion guard.** If the environment variable `AGENT_SKILLS_DELEGATE` is
set, or your brief says you are a delegate, do the asked work directly. Do
not orchestrate, delegate, or watch a pull request.

Bring the idea up to date, not only the branch. A rebase with no conflicts
says the text still applies. It does not say the change still belongs.

## What the request allows

Asking for this skill allows rebasing the pull request's own branch and
pushing it with a lease. It does not allow merging, closing, changing the
base branch, growing the scope, or posting a comment. Each of those needs the
owner's say.

## 1. Read what the pull request was for

Fetch first: the PR's head and its real base branch. Do not assume the base
is `main`, and do not trust a local branch to be current.

- Record the URL, state, base branch, head repository and branch, head SHA,
  author, checks and review state, and the merge base
  (`git merge-base <head SHA> origin/<base>`).
- Read the title, the body, linked issues, the commits, the review threads
  and the whole diff.
- Write the goal in one sentence: the smallest thing the PR was trying to
  do. Judge the implementation only after that.

Changes in the checkout that are not yours belong to the user: never stash,
reset or commit them. If the checkout is dirty or in use, work in a separate
worktree at the PR's head.

## 2. Read what changed around it

Look at what landed on the base since the merge base:
`git log <merge base>..origin/<base>`, with the diffs for the paths this PR
touches. Search merged and open PRs for the same problem and the same code.

Overlapping lines are the smallest part of it. Ask:

- Was the same problem already solved another way?
- Did the APIs, types, schemas or dependencies the PR relies on change?
- Do the PR and the base now both own the same behavior or invariant?
- Was the code it changes deleted, moved or simplified on purpose?
- Would landing it bring back an old behavior, or leave two ways to do one
  thing?
- Is the benefit still worth the cost of keeping the code?

## 3. Decide before you push

| Disposition | When | Then |
|---|---|---|
| **MODERNIZE** | The goal is still useful and the implementation is still the right shape. | Rebase, check and push (step 4). |
| **REWORK** | The goal is still useful, but a mechanical rebase would keep the wrong implementation. | Describe the smallest rewrite that would work, and stop. Do the rework only if the user asked for that too. |
| **CLOSE** | The PR was replaced, is obsolete, points the wrong way, or is no longer worth its cost. | Give the evidence and stop. Do not rebase it and do not close it. |

Recommend CLOSE when the evidence says so. Age is not evidence, and the work
already put in is not a reason to keep a PR open.

## 4. Rebase (MODERNIZE only)

1. Make a local branch or a worktree at the recorded head.
2. Rebase onto the base you fetched.
3. Resolve each conflict by what the PR is for and what the base now
   requires. Under `orchestrate` a conflict is code and goes to a coder. A
   conflict that turns out to be a disagreement about design or product is
   not yours to settle: go back to step 3 of this skill and decide again.
4. Compare the series before and after with
   `git range-diff <merge base>..<old head> origin/<base>..<new head>`, and
   read the final diff. Nothing the PR meant to do is gone, and nothing the
   base already replaced came back.
5. Run the repository's checks for the touched area. Tell a failure the base
   has too from one the rebase caused.
6. Push with `git push --force-with-lease=<branch>:<old head SHA>`. A bare
   `--force-with-lease` trusts the local remote-tracking ref, which any fetch
   moves. If the lease fails, someone else pushed: fetch and start again
   from step 1.

## 5. Report

Start with the disposition and its reason. Then:

- what changed on the base that matters to this PR
- the design conflicts you found, or that you looked and found none
- the rebase and the push, if you did them, with the old and new head SHA
- the checks you ran and their results
- what is left for the owner to decide, with the PR link

Keep what you saw apart from what you judge, and say what you could not
check.
