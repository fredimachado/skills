# Working on this repository

## Scripts come in pairs

- Every script exists as `.ps1` (Windows, PowerShell 7) and `.sh` (Linux and macOS, plain
  POSIX sh, no pwsh). Change both together: same parameters, same messages, same exit
  codes.
- Tests in `tests/` (Pester 5) cover both through `TEST_SCRIPT_KINDS` (`ps1`, `sh`); CI runs
  ps1 on Windows and sh on Ubuntu and macOS. Locally: Pester on Windows for ps1, and
  `TEST_SCRIPT_KINDS=sh` under pwsh in WSL or Linux for sh.

## Portable sh

- It must run under dash and macOS: no bashisms, no `sed -i`, `readlink -f`, `timeout` or
  `flock`. Kill a process tree with `pgrep -P`; lock with `mkdir`.
- Don't name functions after bash builtins (`complete` fails shellcheck SC3044).
- Write empty assignments as `a='' b=''`, not `a= b=` (SC1007).
- CI runs `shellcheck --shell=sh --severity=warning`; if it isn't installed, at least run
  `sh -n`.
- jq must stay compatible with 1.6 (Ubuntu 20.04 ships it).
- New `.sh` files need the executable bit (`git update-index --chmod=+x`) and LF line
  endings (`.gitattributes` enforces it).

## Tests never touch the real machine

- Give every script under test a temporary HOME/USERPROFILE and piped input. A script that
  sees a terminal asks questions and hangs the run.
- Questions are gated on a terminal check plus an override for tests (`SYNC_APM_PROMPT`,
  `INSTALL_ROLES_PROMPT`). Without a terminal, say what to run and exit 2.
- On macOS, temp paths under `/var` resolve to `/private/var`: compare real paths.

## Repository rules

- `.gitignore` is an allow-list (the repo can be cloned into `~/.agents/skills`): a new
  top-level file or folder must be added to it.
- Model ids live only in `scripts/models.txt`, the menu the install questions offer. None
  in skills, scripts or tests: tests use placeholders such as `model-a`, or read
  `models.txt`. No tokens or account details anywhere.
- A skill file names another file by a path that exists, and a section of it by words
  from its heading or bold lead-in, written as `` `file or skill`, "words" ``.
  `tests/skill-text.Tests.ps1` checks both, and that `README.md` lists every skill in its
  table and gives it a box in its diagram. Without Pester,
  `pwsh -NoProfile -File tests/skill-text.ps1` prints the problems.
- Every skill has a guide, `docs/<name>.md`, with the headings "What it solves", "How it
  works" and "How it connects", written in plain words for someone who has never used the
  skill. The same test checks that it exists, that `README.md` links to it and that its
  links resolve.
- With every change, read the diagram in `README.md` and the guides in `docs/` again, and
  update them in the same commit. Read the guide of each skill you touched and of each
  skill that names it: a new step, a changed cap, a renamed role or a new link between
  two skills changes them. The test cannot tell whether they are still true; you can. A
  new skill needs a box in the diagram, a row in the table and a guide. Check the rest of
  `README.md` the same way.
- `install` never replaces a real folder or a link that points elsewhere; keep it that way.
- Commit to `main` as fast-forwards, with no attribution lines.
