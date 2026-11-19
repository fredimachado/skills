# How each host does what differs

Skill text names no harness tool. When a skill needs one of the things
below, it points here. This is the only file that names host tools.

**Sources.** "Reported" means the CLI listed the tool and its parameters when
asked about its own tool definitions in headless mode on 2026-11-18
(codex-cli 0.166.0 `codex exec`; Cursor Agent 2026.11.13 `cursor-agent -p`).
"Docs" means the vendor's documentation. "Not confirmed" means nobody has
checked it yet; treat it as missing. Tool sets can differ between headless and
interactive sessions, and between versions: if a tool named here is not in
your tool list, use the fallback in the same row.

## Spawn a subagent on a chosen model

| Host | How |
|---|---|
| Claude Code | Agent tool, `subagent_type: "general-purpose"`, `model` and `effort` from the role. The Agent tool takes only the model aliases Claude Code lists for it; a role model it does not accept is unavailable. |
| Codex | `spawn_agent` with `task_name`, `message` (the brief), `model` and `reasoning_effort` (reported). Needs the `multi_agent` feature, on by default in 0.166.0 (`codex features list`). An explicit `model` on the spawn wins over `[agents]` defaults in config (docs). |
| Cursor | `Task` with `description`, `prompt` (the brief), `subagent_type: "generalPurpose"` and `model` (reported). Effort goes inside the model string: `<model>[effort=high]` (`cursor-agent --help`). Cursor may silently fall back to another model when a plan or admin blocks the one asked for (docs): check the model the subagent reports and treat a different one as unavailable. |

## Continue the same subagent

| Host | How |
|---|---|
| Claude Code | SendMessage with the agent id the Agent tool returned. |
| Codex | `followup_task` with `target` (the spawned agent) and `message` (reported). `send_message` delivers without starting a turn; do not use it for fix rounds. |
| Cursor | `Task` again with `resume: <agent id>` and the follow-up as `prompt` (reported; docs). |

## Wait for a subagent

| Host | How |
|---|---|
| Claude Code | Background agents notify on completion. Wait for the notification; do not poll. |
| Codex | `wait_agent`, optionally with `timeout_ms` (reported). |
| Cursor | A foreground `Task` returns its result. With `run_in_background`, output goes to `~/.cursor/subagents/` (docs); prefer foreground. |

## Give a coder its own worktree

| Host | How |
|---|---|
| Claude Code | Agent tool with `isolation: "worktree"`. The coder commits to its worktree branch; you merge it after review. |
| Codex | No worktree parameter on `spawn_agent` (reported), and subagents inherit the parent's sandbox (docs). For parallel coders, create a worktree per coder with `git worktree add` and run each through the CLI route with that `-WorkDir`; otherwise run slices sequentially. |
| Cursor | No worktree parameter on `Task` (reported). Same as Codex: a `git worktree add` per coder and the CLI route, or sequential slices. |

## Create branches and commit

| Host | How |
|---|---|
| Claude Code | Git works under the session's normal permissions. |
| Codex | Under the `workspace-write` sandbox, `.git` and a worktree's resolved `gitdir` are read-only by design (Codex docs): `git switch -c` and `git commit` fail (observed 2026-11-18 and 2026-11-19, 0.166.0; neither `--add-dir <.git>` nor `--approve-for-me` changed it). An orchestrator on Codex stops before coding and says so, unless the owner runs the session with a sandbox that allows it. A Codex coder (as a delegate) leaves its change uncommitted with a commit message in its report; the caller commits it. |
| Cursor | Git works in print mode with `-f` (observed 2026-11-18 and 2026-11-19). |

## Read-only subagent

No host enforces read-only on a native subagent per spawn: Claude Code and
Cursor subagents get the parent's tools, and Codex subagents inherit the
parent's sandbox. A native read-only role rests on its brief. The CLI route
enforces read-only with each CLI's own flag, and the script (`agent-run.ps1` or `agent-run.sh`) fails a
read-only run that changed the work directory. What each CLI's read-only
mode still allows is in `claude-cli.md`, `codex-cli.md` and `cursor-cli.md`.

## Run the CLI route

On Windows, `pwsh -NoProfile -File <absolute path>/agent-run.ps1 ...` from
any shell. On Linux and macOS, `sh <absolute path>/agent-run.sh ...` with the
same parameters; it needs `jq`. The delegate CLI needs network access and writes its own session files.

| Host | How |
|---|---|
| Claude Code | Run it with the shell tool; in the background when it may take longer than the tool's time limit, then wait for the notification. |
| Codex | Under `workspace-write` the sandbox has no network, so a delegate CLI fails to reach its API (observed 2026-11-19: Claude reported `ECONNREFUSED`). The Codex session needs `-c sandbox_workspace_write.network_access=true` (or that setting in its config) for this route; it worked with it (observed 2026-11-19). Without it, report the role unavailable with that reason. |
| Cursor | Run it with the shell tool in print mode with `-f` (observed 2026-11-19). |

## Ask the owner a question

| Host | How |
|---|---|
| Claude Code | `AskUserQuestion`. |
| Codex | `request_user_input` (reported as available in Plan mode) or `request_user_input_async` (reported). |
| Cursor | No question tool in headless mode (reported); interactive not confirmed. Fallback: ask in a plain message with the context and your recommended answer first, and end the turn. |

Fallback on every host when the tool is missing or returns nothing: take the
safe path (do not push, do not merge, do not delete) and lead your next
message with the question.

## Wait on a long command

| Host | How |
|---|---|
| Claude Code | Run it in the background; the session is woken when it exits. For a stream of events, use Monitor so each output line wakes you. |
| Codex | `exec_command` with `yield_time_ms`; continue or collect with `write_stdin` on its `session_id` (reported). |
| Cursor | `Shell` with `block_until_ms: 0` to background it, then `AwaitShell` (reported). |

Never write a polling or sleep loop of your own on any host.
