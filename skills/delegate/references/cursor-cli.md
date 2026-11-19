# Cursor Agent CLI (`cursor-agent`) as a delegate

Checked on Cursor Agent 2026.11.17, Windows 11, 2026-11-19. Flags change
between versions: run `pwsh -NoProfile -File <delegate dir>/scripts/agent-run.ps1
-Check` before relying on this page.

On Windows the CLI installs `cursor-agent.cmd`, `cursor-agent.ps1` and
`agent.cmd`; Git Bash cannot resolve the bare name `cursor-agent`. The script
resolves it with `Get-Command`, so this does not matter there.

## What `agent-run.ps1` runs

| Need | Flags |
|---|---|
| Headless, prompt on stdin | `cursor-agent -p` with the brief piped in |
| Model, effort | `--model '<model>[effort=<level>]'`; without effort just `--model <model>`. Not every model takes an effort parameter: the CLI refuses the model then ("Cannot use this model"), and the script reports `unavailable` |
| Work directory | `--workspace <dir>`, and `--trust` so print mode does not stop at the trust prompt |
| Other readable directories | `--add-dir <dir>` once per directory: the skills folder and each `-ReadDir` |
| Output | `--output-format json`: one `result` object with `result`, `session_id`, `is_error` |
| Schema | no flag. The script appends the schema to the brief, takes the JSON object from the reply and validates it |
| Resume | `--resume <session_id>`; the session id stays the same and the delegate keeps its context (observed 2026-11-19) |
| Read-only | `--mode plan` |
| Write | `-f` (allow commands); print mode edits files by default |
| Signed in | `cursor-agent status` exits 0 and does not say "not logged in" |
| Models offered | `cursor-agent --list-models`, one `<model> - <name>` per line |

Cursor does not report the model it ran in print mode, so the script reports
the one requested.

## What read-only still allows

- `--mode plan`: reading files. The shell is refused, so it cannot run
  `git diff` or tests: put the diff and the check output in the brief.
- **Plan mode may still edit markdown and canvas files** (the agent said so
  when refusing a `.txt` write, observed 2026-11-19). The script's check that
  the work directory did not change catches that after the fact. For a
  reviewer, prefer a work directory you can throw away.
- **Do not use `--mode ask` as read-only.** Observed 2026-11-19: it refused
  the shell but let the agent create a file.
- `--sandbox enabled` is not available on Windows ("Sandbox requires macOS
  or Linux").

## Write mode

Observed 2026-11-19 in a linked worktree with `-f`: the delegate edited,
ran `node`, and committed with `git`. Cursor adds a `Co-authored-by: Cursor`
trailer to its commits.

## Notes

- User-level Cursor hooks run in the delegate. A `preToolUse` hook that fails
  under the CLI's shell can refuse tool calls.
- Runs can be slow: a read-only review of a ten-line diff took about six
  minutes on one model (2026-11-19). Set `-TimeoutSec` accordingly.
