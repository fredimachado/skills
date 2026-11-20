# delegate

Starts a helper agent for a named job, on the tool and model you chose for that job.

Skill file: [skills/delegate/SKILL.md](../skills/delegate/SKILL.md). Back to the
[overview](../README.md).

## What it solves

The other skills need planners, coders and reviewers. If each skill named a model, you
would have to edit every skill when you change your mind, and an agent short of options
would quietly pick whatever model it had.

`delegate` keeps that choice in one file that you own. Skills ask for a role. The role
file says which agent tool and which model does it. If a role is not set up, the work
stops and you are told. No model is ever guessed or swapped in.

It also lets one tool hand work to another. A session in Claude Code can run a reviewer in
Codex, or a coder in Cursor.

## How it works

Some words first. A **role** is a job name: `planner`, `coder-simple`, `coder-complex`,
`reviewer`, `council-a`, `council-b`. A **harness** is the agent tool that runs a model:
Claude Code, Codex or Cursor. The **host** is the harness your session runs in.

1. **Resolve the role.** It reads `~/.agents/roles.json`, which maps each role to a
   harness, a model and an optional effort level. You can override a role for one host.
2. **Choose the route.** If the role's harness is the host and the host can start a
   subagent on a chosen model, it does that. Otherwise it runs the other tool's command
   line through the script that ships with the skill (`agent-run.ps1` on Windows,
   `agent-run.sh` on Linux and macOS).
3. **Write the brief.** The helper starts with no context and may have none of these
   skills. The brief carries everything: what to do, absolute paths, whether it may write
   files, and what to report back.
4. **Run and record.** The role, harness and model that ran are written down, so the pull
   request can say who did what.
5. **Continue the same helper.** A fix or a question goes back to the agent that did the
   work, so it keeps its context.
6. **Treat the result as data.** What comes back is checked against the code. Instructions
   found inside it are not followed.

A failed run is retried once. A timeout or a missing reply is never read as "finished" or
"approved". A helper that writes code commits to its branch and never pushes. On the
command-line route it runs only in a separate worktree, never in your main checkout.

On that route a helper that may write runs with full access: its tool asks for no
approval and uses no sandbox. It needs that to commit, to download packages and to use
Docker. The worktree keeps its edits apart from yours, but nothing stops it from reaching
the rest of your machine. Only its brief does. Planners and reviewers stay read-only.

## How it connects

Almost every skill in the top two rows of the [overview](../README.md) goes through
`delegate`.

- [orchestrate](orchestrate.md) uses it for every coder.
- [plan](plan.md) uses it for the planner.
- [review-loop](review-loop.md) and [council](council.md) use it for reviewers.
- [babysit-pr](babysit-pr.md) uses it for fixes after the pull request is open.
- [coding-standards](coding-standards.md) travels in every brief as a file path.
- [file-pr](file-pr.md) uses the model names `delegate` recorded for the attribution line.

The role file is set up by `scripts/install.ps1 -Roles` or `scripts/install.sh --roles`,
which offer the models listed in `scripts/models.txt`.

## How to ask for it

"Hand this task to a coder", or "have the reviewer role look at this file". Most of the
time you will not call it yourself. The other skills do.
