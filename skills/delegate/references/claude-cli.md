# Claude Code CLI (`claude`) as a delegate

Checked on Claude Code 2.1.327, Windows 11, 2026-11-19. Flags change between
versions: run `pwsh -NoProfile -File <delegate dir>/scripts/agent-run.ps1
-Check` (Windows) or `sh <delegate dir>/scripts/agent-run.sh -Check` (Linux,
macOS; needs `jq`) before relying on this page.

## What `agent-run.ps1` runs

| Need | Flags |
|---|---|
| Headless, prompt on stdin | `claude -p` with the brief piped in |
| Model, effort | `--model <id or alias>`, `--effort low\|medium\|high\|xhigh\|max` |
| Work directory | the process working directory (there is no flag) |
| Other readable directories | `--add-dir <dir>...`: the skills folder and each `-ReadDir`. Without it a read-only delegate is refused files outside the work directory, such as the standards file (observed 2026-11-19) |
| Output | `--output-format json`: one `result` object with `result`, `session_id`, `is_error`, `modelUsage` |
| Schema | `--json-schema '<schema JSON>'`; the validated object is in `structured_output` |
| Resume | `--resume <session_id>`; the session id stays the same |
| Read-only | `--permission-mode dontAsk --tools Read,Grep,Glob,Bash --allowedTools "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git status:*)" "Bash(git rev-parse:*)"` |
| Write (full access) | `--permission-mode bypassPermissions` |
| Signed in | `claude auth status` prints JSON with `loggedIn` |
| Models offered | no list command; an unknown model fails the run |

The model actually used is the `modelUsage` key with the most output tokens.
The script compares it with the one asked for and reports `unavailable` when
they differ.

## What read-only still allows

- Reading and searching files, and the git commands listed above. Any other
  command is refused without a prompt (`dontAsk`), and so is every edit.
- It cannot run the tests. Put test and linter output in the brief.
- Observed 2026-11-19: `git diff --stat` and a file read worked; a write
  through Bash was refused and listed in `permission_denials`.

**Do not use `--permission-mode plan` for a delegate.** Observed 2026-11-19:
in plan mode with a small model requested, the run reported a different,
larger model in `modelUsage`. That is a substitution.

## What write mode allows

Everything. `bypassPermissions` skips every permission check, and Claude Code
has no sandbox of its own here, so the delegate can edit, run any command,
reach the network and use Docker. Observed 2026-11-20 in a linked worktree:
the delegate edited a file, ran `git commit`, fetched a web page with `curl`
and read the server version from `docker version`.

- `auto` is not enough: a classifier decides each action, and by default it
  blocks downloading and executing code (docs, read 2026-11-20). In print
  mode a blocked action does not run and the delegate carries on without
  it, so a package install or a Docker command is not sure to happen.
  `acceptEdits` allows edits but refused `git commit` in print mode
  (observed 2026-11-19).
- On Linux and macOS, Claude Code refuses to start in `bypassPermissions`
  as root or under `sudo`, except inside a sandbox it recognizes. Managed
  settings can turn the mode off with
  `permissions.disableBypassPermissionsMode` (docs, read 2026-11-20). The
  run then fails; report the role as unavailable with that reason.

## Notes

- `claude -p` skips the workspace trust dialog; only run it in directories
  you trust (`claude --help`).
- User-level skills, `CLAUDE.md` and hooks load in the delegate as in any
  session.
- This page is not named `claude.md`: on a case-insensitive file system
  Claude Code would load that name as a `CLAUDE.md` memory file.
