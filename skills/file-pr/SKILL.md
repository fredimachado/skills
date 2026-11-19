---
name: file-pr
description: Open a real, problem-first pull request for the current branch, with how it was verified, what was not, deferred findings, the council record when one ran, and the models and harnesses that made the change. Use when the user asks to file, open, create or raise a pull request, or when orchestrate reaches its pull request step. Do not use to update or comment on someone else's pull request, or when running as a delegate.
---

# File PR

**Recursion guard.** If the environment variable `AGENT_SKILLS_DELEGATE` is
set, or your brief says you are a delegate, do the asked work directly. Do
not orchestrate, delegate, or watch a pull request.

## Before filing

1. **Is there one already?** `gh pr list --head <branch> --state open`. If a
   PR exists, update it only if the user asked; otherwise report its link.
2. **Is it the change you mean?** Review the diff against the base (usually
   `origin/<default branch>`): the contents match the goal, and nothing else
   rode along (stray files, debug output, unrelated edits).
3. **Is the head what was reviewed and verified?** Push only a head whose
   review and verification are recorded. A later commit that changes behavior
   needs its own review first. Never push to the default branch.

## Title

Titles often become commit messages: follow the repository's conventions
(read recent merged PRs and `git log`). Prefer a short, human title that says
why the change matters, not which mechanism changed.

## Description

In this order:

1. **The problem**, in plain words, from the user's original request.
2. **The solution**, briefly. Not an inventory of every edit.
3. **How it was verified** in the running application: what was driven and
   what was seen, plus the checks that ran.
4. **What was not verified**, and why.
5. **Deferred findings**, by id, each with its reason.
6. **Council**, when one ran: rounds, each seat's role, harness and model, and
   its verdict per round (`../council/SKILL.md`, "Record").
7. **Attribution**, last: `Created with <model> in <harness>.` Include every
   model that wrote or reviewed part of the change, with its harness, as the
   harness or `agent-run.ps1` reported it. If a model's identity is unknown,
   name the harness and do not guess a model.

## Check before you submit

Read the title and the whole body for secrets and private details: tokens,
keys, internal hostnames, personal names or emails that are not already
public in the repository, private paths. Remove them.

## Open it

A real pull request, not a draft, so review bots run. If `gh pr create` fails
because the GraphQL rate limit is spent, open it through REST:
`gh api repos/<owner>/<repo>/pulls -f title=... -f head=... -f base=... -F body=@<file>`.
Put the link in the task file when there is one. If the user also asked to
watch it, or the finish condition is `merge-ready`, continue with
`babysit-pr` (`../babysit-pr/SKILL.md`).

Do not post follow-up comments unless they serve the user's request, and
never without the owner's say.
