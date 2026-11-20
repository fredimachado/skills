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
| Write (full access) | `--dangerously-bypass-approvals-and-sandbox`, on a new run and on resume |
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

## What write mode allows

Everything. `--dangerously-bypass-approvals-and-sandbox` turns off the
sandbox and every approval, so the delegate can edit, commit, reach the
network and use Docker. Observed 2026-11-20 in a linked worktree, on a new
run and on a resumed one: the delegate edited a file, ran `git commit`,
fetched a web page with `curl` and read the server version from
`docker version`.

The `workspace-write` sandbox is not enough for a coder. It keeps `.git` and
a worktree's resolved `gitdir` read-only by design (Codex docs), so
`git commit` failed creating `index.lock` (observed 2026-11-19, also with
`--add-dir <repo>/.git` and with `--approve-for-me`), and it has no network
by default. Both still apply when Codex is the **host**: see `hosts.md`,
"Create branches and commit" and "Run the CLI route".

## Notes

- User-level Codex skills and `AGENTS.md` load in the delegate.
- `codex exec` outside a git repository needs `--skip-git-repo-check`; the
  script does not pass it, so the work directory must be a repository.
