---
name: bootstrap-verification
description: Set up a project-specific verification skill (named verify-APPNAME) so agents can build, run and check an app themselves and collect evidence that changes work. Works for web apps, APIs/services, CLIs, terminal UIs, desktop apps (Qt, GTK, WPF, macOS…) and Electron. Generates a reproducible CLI harness, scenarios and a feature map. Use when the user wants agents to verify their own work, test the running app, reproduce bugs automatically, add a "definition of done", set up smoke/e2e checks for agents, build a feature map, or asks how agents can know a change really works, even if they don't mention skills.
---

# Bootstrap verification

Agents can only be trusted with more autonomy when they can check their own work against
the real, running app, the same way every time. This skill builds that capability for one
app: a `verify-<app>` skill in the repo, containing:

- **`scripts/verify.py`**: a config-driven harness (Python 3 stdlib only) that builds the
  app, starts services, waits until they're ready, runs scenario steps, stops everything, and
  stores evidence in `.verify/runs/`. Agents call it instead of improvising scripts.
- **`verify.config.json`**: the app-specific part: build command, services, scenarios,
  budgets.
- **`feature-map.md`**: what each feature does, how a user reaches it, where its code
  lives, which scenarios cover it. This lets agents decode vague requests and bug reports.
- **`scripts/drivers/`**: helpers for web/Electron (Playwright), terminal UIs (tmux) and
  desktop screenshots.

The template lives in `templates/verify-app/` inside this skill.

## Procedure

### 1. Check what exists

Look for existing verification pieces in every agent's folders, not just your own:
`.claude/`, `.agents/`, `.cursor/`, `.github/`, `docs/`. Look for `verify-*` or
"verification" skills, control/drive scripts, feature maps or route inventories, e2e suites,
smoke scripts, `make run` targets.

- If a harness exists, extend it instead of creating a second way to verify. Two harnesses
  is one too many. Keep a good existing driver (for example a project's own browser control
  CLI) and add scenarios around it rather than replacing it.
- **Audit existing maps and recipes before trusting them.** They drift silently whenever UI
  copy changes. Check every quoted UI string in them against the source (`verify.py
  audit-map` does this once a config exists), and run a couple of recipes for real.
- If there are **several maps** (say, a pipeline inventory and a live-drive recipe folder),
  merge them into one. Duplicated maps drift in different directions; in practice both
  end up partly wrong.
- When moving or merging, ask the user first. Then turn the old files into one-line pointers
  to the new location, so no agent follows a stale copy, and update every instruction file
  that referenced them (AGENTS.md, other skills).

### 2. Understand how the app runs

Read, in roughly this order of trustworthiness:

1. **CI configuration** (`.github/workflows`, `.gitlab-ci.yml`, `azure-pipelines.yml`, etc.).
   What CI actually runs is the truth.
2. Build files and task runners: `package.json` scripts, Makefile, justfile, Taskfile,
   CMakeLists.txt / presets, *.sln / *.csproj, Cargo.toml, pyproject.toml, go.mod,
   build.gradle, docker-compose.yml, Dockerfile.
3. README / CONTRIBUTING / docs.
4. Existing tests, especially e2e/integration ones, which show how the app is driven today.

Work out: the app kind(s) (web, service, CLI, terminal UI, desktop, Electron, or a mix);
build command; how to start each process; ports and URLs; required env vars and secrets;
external dependencies (DB, queues) and how to start them locally; test data/fixtures; and
whether it can run headless.

Then **try it**: build and run the app once by hand before writing any config. Note every
surprise; those become *Gotchas*.

### 3. Choose drivers and evidence

Read `references/drivers.md` and pick, per app kind, how to drive the app and what evidence
to collect. Prefer tools the project already uses. Key decisions:

- **Web / Electron:** the project's existing e2e runner called from `run` steps (one
  scenario per feature, targeting that feature's specs), or the bundled Playwright driver
  (needs `pip install playwright` + a browser) if there is none. For exploratory proofs, a
  stateful **control CLI** (launch / doctor / drive / cleanup with an instance file) is worth
  having; scenarios can call it step by step, with `"always": true` on the cleanup step.
- **Service / API:** built-in `http` steps plus a `log` check for errors.
- **CLI:** `run` steps with golden files.
- **Terminal UI:** the tmux driver (or the TUI framework's test harness).
- **Desktop:** usually an **automation seam** in the app (a test-only flag that exposes
  state and actions). This changes product code, so **ask the user** before adding it. If
  they decline, fall back to the UI framework's test tools, the accessibility tree, logs and
  screenshots, and say clearly what can't be verified.

**Isolation.** The harness must only drive processes it started itself: its own port, its
own browser profile, its own data. Never attach to a developer's running dev server: it may
be serving another branch, a stale build, or someone's half-edited state, and a pass against
it proves nothing. Watch for test-runner settings that silently reuse a server (Playwright's
`reuseExistingServer: !process.env.CI`): set `CI=1` in scenario env, or give the harness its
own port, so a busy port fails loudly instead.

The harness's own `up` instance can go stale too. `up` records the commit it started at;
`doctor` fails if that instance has died or the tree has moved to another commit, and notes
files edited since it started; `run` refuses while a service it needs is still up.

**Two runs on one machine.** Agents work in parallel worktrees, so the harness may be started
twice at once. Keep each run's data under `{run_dir}`, and do not fix names (containers,
compose projects, databases) or ports to one value that both runs would claim: take them from
something each worktree can set differently. If the app cannot run twice on one machine, write
that under *Gotchas*, so a caller runs one worktree at a time.

If something needs a decision only the user can make (adding a seam, installing a browser,
test credentials), ask once with a concrete recommendation.

### 4. Create the skill from the template

Put it where the project's agent skills live, named after the app, e.g.
`.claude/skills/verify-<app>/` (Claude Code), `.agents/skills/verify-<app>/`, or whatever
skills directory the repo already uses. Ask if unclear.

```bash
cp -r <this-skill>/templates/verify-app <skills-dir>/verify-<app>
mv <skills-dir>/verify-<app>/SKILL.md.template <skills-dir>/verify-<app>/SKILL.md
```

(The template is stored as `SKILL.md.template` so it isn't mistaken for a real skill.)
Replace the placeholders in the copied files:

| Placeholder | Value |
|---|---|
| `__APP_SLUG__` | short kebab-case name (`shop`, `viewer`, `orders-api`) |
| `__APP_NAME__` | human name |
| `__APP_KIND__` | e.g. `web app + API`, `Qt desktop app`, `terminal UI` |
| `__SKILL_PATH__` | repo-relative path of the new skill dir (e.g. `.claude/skills/verify-shop`) |
| `__GOTCHAS__` | bullet list of the surprises from step 2 (or "None yet.") |

Delete drivers that don't apply (e.g. `tui_tmux.py` for a web app), so agents aren't
tempted by irrelevant tools.

### 5. Write the config

Read `references/config-reference.md` for every option and full examples per app kind.
Write:

- `build`, `services` (with real readiness checks, not delays), `requires`, `vars`, `env`.
- **`smoke`**: fast (ideally under a minute), covers "it builds, starts, and the main path
  works without errors". This runs after every change, so speed matters.
- **2–5 feature scenarios** for the most important or most-changed features. Each should
  assert something a user would care about, plus "no errors in logs/console".
- `budgets` only where there's a meaningful performance expectation. Start with generous
  numbers from real runs; tighten later.

Prefer list-form commands and `{python}` so the config also works on Windows. Exception:
`npm`, `npx`, `yarn` and other Node shims are `.cmd` files on Windows, so call them as shell
strings (`"run": "npm run build"`) or they won't be found.

Add a **`map`** scenario that runs `check-map` and `audit-map --strict`, and a **`gates`**
scenario that mirrors the CI job (lint, build, unit tests, coverage), so "is it done?" is one
command.

### 6. Write the feature map

Fill `feature-map.md` with the app's real features. Find them in the code, not just the
docs: router/route tables, navigation and menu definitions, command palettes and keyboard
shortcut registrations, CLI argument parser definitions, QML pages / views / windows,
API route registrations. For each feature: `id`, `what`, `reach`, `ui`, `code`, `verify`,
and `notes` where useful. If the project has e2e specs, add an `e2e` field per feature and
list it in `map_path_fields` so moved or deleted specs are caught.

Aim for the granularity a user would describe ("search", "export to PDF", "settings →
accounts"), not every component. Set `map_coverage` to everything that must belong to some
feature (e.g. `src/pages/*Page.tsx`, `e2e/*.spec.ts`) so `check-map` flags new, unmapped
features and specs.

For bigger apps, keep `feature-map.md` as a short index and put each feature's full recipe
(entry points, steps, observable end state, gotchas) in `features/<id>.md`, linked through a
`recipe` field listed in `map_relative_fields`.

**Don't duplicate selectors.** The executable specs are the source of truth for exact
handles. Recipes should name entry points, stable landmarks (headings, nav, key buttons) and
the end state, and point at the spec for the rest. Long copied selector lists are exactly
what goes stale. Set `map_handle_sources` (UI source globs) so `audit-map` can flag recipe
strings that no longer exist; it recognizes runtime-built strings like `Remove ${name}`, and
`map_handle_ignore` covers test data typed into forms.

### 7. Prove it works, and that it can fail

```bash
python <skill>/scripts/verify.py doctor
python <skill>/scripts/verify.py run --all
python <skill>/scripts/verify.py run map        # check-map + audit-map --strict
```

Iterate until everything passes reliably. Run `smoke` at least twice to catch flakiness.
**Run every recipe you write or rewrite**, not just the scenarios: a recipe that has never
been executed is a guess, even when it was written carefully from the specs.
Then **show that it catches problems**: temporarily break something the smoke scenario
should detect (an expected text, a route, a build flag), confirm the run fails with a clear
message, and revert. A check that has never failed may not be checking anything.

### 8. Wire it in

- Add `.verify/` to `.gitignore`.
- Add a short *Definition of done* to the project's agent instructions (AGENTS.md /
  CLAUDE.md / equivalent), e.g.:
  > Before reporting a change as done, run the `verify-<app>` skill's smoke scenario plus the
  > scenarios for the affected features (see its feature-map.md), and include the
  > `verify.py last` summary in the PR.
- Optionally add a CI job that runs `verify.py run smoke map`, so the harness and the map
  can't silently rot.
- When editing existing files (AGENTS.md, .gitignore), keep their line endings (CRLF on
  many Windows checkouts) so the diff shows only your change.

### 9. Report

Tell the user: the app kinds covered, the scenarios created, the commands, any tools they
need to install, what couldn't be automated and why, and suggested next scenarios.

## Evidence standard

Put this in the generated skill (the template has it) and hold proofs to it:

- The real user path: click, type, submit, navigate. Not internal setters, store calls,
  test-only hooks, or data pasted into storage from a console.
- The action **and** the resulting state, not only a final screenshot.
- A side effect next to the visible UI: URL, persisted record, storage key, API response,
  or a second screen that re-reads the same data.
- An accessibility/structure snapshot plus a screenshot (or text capture) showing the
  feature.
- Every entry point the map lists. An entry point that doesn't work is a failure for that
  path, not a pass through a different one.
- A verdict of verified, not verified or inconclusive. A check that couldn't run, or ran on
  a different surface than the one users touch, is inconclusive, and that is not a pass.

## Monorepos and multiple apps

One `verify-<app>` skill per independently runnable app keeps descriptions precise and
scenarios fast. If apps are always run together (frontend + its API), keep them in one
skill as multiple services.

## Maintenance

The harness only builds trust while it's accurate. Run the `map` scenario in CI or in
periodic gardening, add scenarios as features are added, and record running quirks under
*Gotchas*.

The static checks (`check-map`, `audit-map`) catch stale paths and stale UI text, not
entries that have stopped describing the behaviour or recipes that no longer work. The
generated skill has an **Audit pass** section for that: `stale-map` lists the features
whose code changed after their map entry, the agent re-reads those, re-runs the recipes,
checks the scenarios can still fail, tightens loose budgets, and reports clean, changed or
blocked. It edits only the skill's own folder. Run it periodically, or let the `garden`
skill trigger it.

When the map and the app disagree, classify it before editing: **doc drift** (fix the
map), **harness gap** (fix the harness and re-run it), or **product regression** (report
it; never edit the map or loosen a scenario so a regression passes). The generated skill
carries the same rule.
