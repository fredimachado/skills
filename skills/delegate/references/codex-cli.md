# Codex CLI (`codex exec`) as a delegate

Checked on codex-cli 0.166.0, Windows 11, 2026-11-19. Flags change between
versions: run `pwsh -NoProfile -File <delegate dir>/scripts/agent-run.ps1
-Check` (Windows) or `sh <delegate dir>/scripts/agent-run.sh -Check` (Linux,
macOS; needs `jq`) before relying on this page.

## What `agent-run.ps1` runs

| Need | Flags |
|---|---|
| Headless, prompt on stdin | `codex exec ... -` |
| Model, effort | `-m <model>`, `-c model_reasoning_effort=<level>` |
| Work directory | `-C <dir>` on a new run; `exec resume` has no `-C`, so the process runs in the work directory |
| Other readable directories | none needed: the sandbox lets Codex read outside the workspace (`-ReadDir` is ignored for Codex) |
| Output | `--json` (JSONL events) and `-o <file>` (final message). The session id is `thread_id` in the `thread.started` event |
| Schema | `--output-schema <file>`; the final message is the JSON |
| Resume | `codex exec resume [options] <thread_id> -`; the thread id stays the same |
| Read-only | `-s read-only`; on resume `-c sandbox_mode=read-only` (no `-s` there) |
| Write | `-s workspace-write`; on resume `-c sandbox_mode=workspace-write` |
| Signed in | `codex login status` exits 0 |
| Models offered | `codex debug models` prints the catalog as JSON; each model has a `slug` |

Codex does not report the model it ran in its events, so the script reports
the one requested.

## What read-only still allows

- Reading files and running commands inside the sandbox: `git diff`,
  `git log` and other commands that only read. Writes are refused by the
  sandbox. Tests that write caches or build output fail.
- Observed 2026-11-19: `git diff --stat` worked; creating a file was refused
  ("writing is blocked by read-only sandbox").

## What write mode allows, and what it does not

- Edits inside the work directory and its writable roots.
- **Not `.git`.** Under `workspace-write`, `.git` and a worktree's resolved
  `gitdir` stay read-only by design (Codex docs). Observed 2026-11-19 in a
  linked worktree: `git add` and `git commit` failed creating `index.lock`,
  also with `--add-dir <repo>/.git` and with `--approve-for-me`. A Codex coder
  therefore cannot commit: its brief must say to leave the change
  uncommitted and put a commit message (why, what, how proved) in its
  report, and the caller commits.
- No network by default. That also matters when Codex is the **host** and
  runs another CLI through `agent-run.ps1`: see `hosts.md`, "Run the CLI
  route".

## Notes

- User-level Codex skills and `AGENTS.md` load in the delegate.
- `codex exec` outside a git repository needs `--skip-git-repo-check`; the
  script does not pass it, so the work directory must be a repository.
