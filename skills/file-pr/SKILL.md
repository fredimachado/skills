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
   rode along (stray files, debug output, unrelated edits). Read it for
   secrets too: a token, a key, a password, an `.env` or credentials file. A
   push cannot be taken back, so stop and tell the user if you find one.
3. **Is the head what was reviewed and verified?** Push only a head whose
   review and verification are recorded. A later commit that changes behavior
   needs its own review first. Never push to the default branch.

## Title

Titles often become commit messages: follow the repository's conventions
(read recent merged PRs and `git log`). Prefer a short, human title that says
why the change matters, not which mechanism changed.

> Bad: `fix(sync): add a per-note save queue`
>
> Good: `fix(sync): stop offline edits from saving twice`

## Description

In this order:

1. **The problem**, in plain words, from the user's original request.
2. **The solution**, briefly. Not an inventory of every edit.
3. **How it was verified** in the running application: what was driven and
   what was seen, plus the checks that ran. Attach a screenshot from the
   verification run when it shows the behavior better than words and there
   is a way to upload it. When a before shot was taken at the base, show
   both.
4. **What was not verified**, and why.
5. **Deferred findings**, by id, each with its reason and what would make
   it worth picking up.
6. **Review**, when a reviewer ran: rounds, the reviewer's harness and model,
   and the final verdict with the head SHA it covers.
7. **Council**, when one ran: rounds, each seat's role, harness and model, and
   its verdict per round (`../council/SKILL.md`, "Record").
8. **Attribution**, last: `Created with <model> in <harness>.` Include every
   model that wrote or reviewed part of the change, with its harness, as the
   harness or `delegate`'s agent-run script reported it. If a model's identity is unknown,
   name the harness and do not guess a model.

Keep it short. Items 3 to 7 take a line or two each unless something went
wrong. Leave out an item with nothing to say, except item 4: there, write
"nothing" only when that is true.

**A pull request template wins.** Look for one first:
`pull_request_template.md` (any case) in `.github/`, the repository root or
`docs/`, or a file in `.github/PULL_REQUEST_TEMPLATE/`. With one, keep its
sections, their order and their headings, replace each placeholder or
comment with content, and add no section of your own. Put the items above
where they fit; an item with no place goes under the template's notes, or at
the end. Item 4 and the attribution are never dropped.

**Issues.** After the solution, or where the template asks, one line per
issue. `Resolves #<n>` only for an issue the user said this work fixes, or
the task file records as resolved, and that `gh issue view <n>` shows open:
the word closes the issue on merge. An issue the work only touches gets
`Related #<n>`. Never guess an issue from a branch name or a search.

The opening is where descriptions go wrong. Bad, an inventory:

> Removed the retry wrapper from `SyncClient`, added `SaveQueue` keyed by
> note, moved the debounce into `useAutosave`, deleted `flushPending`.

Good, the problem and then the fix:

> Editing a note offline saved it twice once the connection came back, and
> the second save overwrote newer text. Saves now queue per note, so only the
> latest one is sent.

## Check before you submit

Read the title and the whole body for secrets and private details: tokens,
keys, internal hostnames, personal names or emails that are not already
public in the repository, private paths. Remove them. Quoted logs, command
output and screenshots count: a screenshot of the running application shows
whatever data was on the screen.

## Open it

A real pull request, not a draft, so review bots run. If `gh pr create` fails
because the GraphQL rate limit is spent, open it through REST:
`gh api repos/<owner>/<repo>/pulls -f title=... -f head=... -f base=... -F body=@<file>`.
Put the link in the task file when there is one. If the user also asked to
watch it, or the finish condition is `merge-ready`, continue with
`babysit-pr` (`../babysit-pr/SKILL.md`).

Do not post follow-up comments unless they serve the user's request, and
never without the owner's say.
