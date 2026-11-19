# verify.config.json reference

## Contents

- [Top-level keys](#top-level-keys)
- [Services and readiness](#services-and-readiness)
- [Scenarios](#scenarios)
- [Step types](#step-types)
- [Metrics and budgets](#metrics-and-budgets)
- [Examples by app kind](#examples-by-app-kind): web, service/API, CLI, terminal UI,
  desktop (Qt/GTK/native), Electron, Windows desktop

---

## Top-level keys

| Key | Type | Meaning |
|---|---|---|
| `app` | string | Display name |
| `kind` | string | `web`, `service`, `cli`, `terminal`, `desktop`, `electron`, `library`, or a mix like `web+service` (informational) |
| `root` | string | Repo root relative to the config file. Default: git top-level |
| `requires` | list | Executables that must be on PATH (`doctor` checks them) |
| `vars` | object | Values for `{placeholders}`, e.g. `"base_url": "http://localhost:5173"` |
| `env` | object | Environment variables for every service and step |
| `build` | string or list | Build command (`verify.py build`, or `run --build`) |
| `services` | object | Long-running processes scenarios can need (see below) |
| `display` | object | `{"xvfb": "never" \| "auto" \| "always", "size": "1920x1080x24"}`. `auto` starts a virtual X display on Linux only if none exists, shared by services and steps |
| `map_path_fields` | list | Map fields holding repo paths that must exist, and that count toward coverage. Default `["code"]`; add e.g. `"e2e"`, `"recipe"` |
| `map_relative_fields` | list | Map fields whose paths are relative to the map file (e.g. `"recipe"` → `features/home.md`) |
| `map_coverage` | list | Globs of files or directories that must each belong to some feature (e.g. `"src/pages/*Page.tsx"`, `"e2e/*.spec.ts"`) |
| `map_handle_sources` | list | Globs of UI source files that `audit-map` searches for the strings quoted in the map and recipes |
| `map_handle_ignore` | list | Regexes for quoted strings `audit-map` should skip (test data typed into forms) |
| `scenarios` | object | Named checks; `smoke` is the default and should be fast |

**Placeholders** work in every string: `{root}`, `{skill}`, `{run_dir}`, `{python}`, and any
key from `vars`. Unknown `{...}` are left untouched, so JSON or shell braces are safe.

**Commands**: a string runs through the shell (pipes, `&&`, globbing); a list runs the program
directly (safer quoting, more portable to Windows). Use `{python}` instead of `python3` so the
same config works on Windows.

## Services and readiness

```json
"services": {
  "api": {
    "cmd": "npm run dev:api",
    "cwd": "backend",
    "env": { "PORT": "4000" },
    "ready": { "http": "http://localhost:4000/health", "timeout": 60 }
  }
}
```

Readiness checks (`ready`, and the `wait` step):

| Check | Ready when |
|---|---|
| `{"http": URL}` | the URL answers with status < 500 |
| `{"port": 5432, "host": "127.0.0.1"}` | a TCP connection succeeds |
| `{"log": "regex"}` | the service's own output matches (or `log_file` for apps that log to a file) |
| `{"file": "path"}` | the file exists (e.g. a ready-marker the app writes) |
| `{"delay": 2}` | after N seconds: last resort, it's either slow or flaky |

All take `timeout` (seconds, default 60). If the process exits before it's ready, the run
fails immediately with the tail of its log. Services start in their own process group and
the whole tree is stopped at the end of the scenario.

## Scenarios

```json
"scenarios": {
  "smoke": {
    "description": "App starts; home page renders without console errors.",
    "features": ["home"],
    "needs": ["api", "web"],
    "steps": [ ... ],
    "budgets": { "startup_ms.web": { "max": 8000 } }
  }
}
```

Steps run in order; the scenario stops at the first failing step unless that step has
`"continue_on_fail": true`. Steps with `"always": true` still run after a failure; use it
for teardown (stopping a browser, cleaning an instance file). Each step can have `name`,
`max_ms` (a time budget for the step), `metric` (record the step's duration under that metric
name) and `env` (extra variables; placeholders allowed).

Top-level `env` values are formatted for every step too, so `"ARTIFACTS": "{run_dir}/artifacts"`
points a driver at the current run's evidence folder.

## Step types

**`run`**: run a command.

| Option | Meaning |
|---|---|
| `run` | string (shell) or list |
| `cwd`, `env`, `timeout` (s, default 120), `stdin` (text fed to the process) | |
| `exit` | expected code: `0` (default), a list, `"nonzero"`, or `"any"` |
| `stdout_contains` / `stdout_not_contains` / `stdout_matches` | string or list; `_matches` is a regex |
| `stderr_contains` / `stderr_not_contains` / `stderr_matches` | same, for stderr |
| `stdout_golden` | path to an expected-output file; created on first run, rewritten with `run --update-golden`; mismatch writes a diff to the evidence dir |
| `normalize` | `{regex: replacement}` applied to stdout before the golden comparison (timestamps, paths, durations) |

**`http`**: `{"http": {"url", "method", "headers", "json" | "body", "status", "contains", "not_contains", "json_equals": {"data.items.0.id": 1}, "timeout"}}`.
`status` defaults to 200/201/204; `json_equals` uses dotted paths (numbers index lists).

**`file`**: `{"file": {"path", "contains", "not_contains", "matches", "min_bytes"}}`. Checks
an output the app or a driver produced.

**`log`**: `{"log": {"service", "contains", "not_contains", "matches", "not_matches"}}`. Checks
a running service's output so far; great for "no errors or warnings during this scenario"
(e.g. `"not_matches": "(?i)\\b(error|exception|qml.*warning)\\b"`).

**`wait`**: same checks as `ready`; add `"service": "name"` to watch that service's log.

## Feature map checks

- `check-map` (errors): every `id` unique; every path in `map_path_fields` exists; every
  `verify` scenario exists; every scenario's `features` exist; everything matched by
  `map_coverage` is claimed by some feature (warnings).
- `audit-map` (advisory, `--strict` to fail): collects UI strings from the map and recipe
  files (inline `code` spans that read like UI text, and `--name`/`--text`/`--label` values
  in command examples) and lists those not found in `map_handle_sources`. It normalizes JSX
  entities and whitespace, and treats template literals (`Remove ${name}`) and JSX text with
  `{expressions}` as patterns, so runtime-built labels don't show up as false alarms.

- `stale-map` (advisory, `--strict` to fail): lists features whose code (the non-relative
  `map_path_fields`) has commits newer than the last edit to their map entry or recipe
  file, with the count and the latest commit. It catches what the other two can't: an
  entry that is well-formed but no longer describes the behaviour. It's a hint, since a
  refactoring flags an entry that is still accurate; editing the entry (its `reviewed:`
  date) clears it. Needs git history, so a shallow clone hides older changes.

A `map` scenario running the first two keeps the map honest in one command. `stale-map`
belongs in the generated skill's audit pass rather than in CI, where it would fail on every
code change that rightly leaves the map alone.

## Metrics and budgets

Metrics come from: service startup time (`startup_ms.<service>`), steps with `metric`, and
any JSON files a driver writes to `{run_dir}/metrics/*.json` (flat `{"name": number}`
objects; `web_playwright.py --metrics NAME` does this). They're saved in `summary.json`, and
`verify.py compare <scenario>` diffs the last two runs.

`budgets` turn metrics into checks: `{"metric": {"max": N, "min": N}}`. A budget whose metric
wasn't produced fails, so a broken driver can't silently pass.

---

## Examples by app kind

### Web app (frontend + API)

```json
{
  "app": "Shop", "kind": "web+service",
  "requires": ["node", "npm"],
  "vars": { "web": "http://localhost:5173", "api": "http://localhost:4000" },
  "build": "npm run build",
  "services": {
    "api": { "cmd": "npm run dev:api", "ready": { "http": "{api}/health" } },
    "web": { "cmd": "npm run dev -- --port 5173 --strictPort", "ready": { "http": "{web}" } }
  },
  "map_coverage": ["src/features/*"],
  "scenarios": {
    "smoke": {
      "description": "API healthy; home renders with no console errors.",
      "features": ["home"], "needs": ["api", "web"],
      "steps": [
        { "name": "api health", "http": { "url": "{api}/health", "json_equals": { "status": "ok" } } },
        { "name": "home renders",
          "run": ["{python}", "{skill}/scripts/drivers/web_playwright.py", "--url", "{web}",
                  "--step", "{\"expect_text\": \"Welcome\"}",
                  "--step", "{\"screenshot\": \"home\"}",
                  "--fail-on-console-error", "--metrics", "home"] }
      ],
      "budgets": { "home.load_ms": { "max": 3000 } }
    }
  }
}
```

### Service / API

```json
{
  "app": "Orders API", "kind": "service",
  "requires": ["dotnet"],
  "vars": { "base": "http://localhost:5080" },
  "build": "dotnet build -c Release",
  "services": {
    "db":  { "cmd": "docker compose up db", "ready": { "port": 5432, "timeout": 90 } },
    "api": { "cmd": "dotnet run --project src/Orders.Api --no-build -c Release",
             "env": { "ASPNETCORE_URLS": "{base}" }, "ready": { "http": "{base}/health" } }
  },
  "scenarios": {
    "smoke": {
      "needs": ["db", "api"],
      "steps": [
        { "http": { "url": "{base}/orders", "method": "POST",
                    "json": { "sku": "A1", "qty": 2 }, "status": 201 } },
        { "http": { "url": "{base}/orders?sku=A1", "contains": "\"qty\":2" } },
        { "name": "no server errors", "log": { "service": "api", "not_matches": "(?i)\\bfail|exception\\b" } }
      ]
    }
  }
}
```

### CLI

```json
{
  "app": "mytool", "kind": "cli",
  "build": "cargo build --release",
  "vars": { "bin": "{root}/target/release/mytool" },
  "scenarios": {
    "smoke": {
      "steps": [
        { "run": ["{bin}", "--help"], "stdout_contains": "Usage" },
        { "run": ["{bin}", "convert", "tests/fixtures/in.csv"],
          "stdout_golden": "tests/golden/convert.txt",
          "normalize": { "\\d+ms": "<ms>" } },
        { "run": ["{bin}", "convert", "missing.csv"], "exit": "nonzero",
          "stderr_contains": "not found" }
      ]
    }
  }
}
```

### Terminal UI

```json
{
  "app": "tasks-tui", "kind": "terminal",
  "requires": ["tmux"],
  "build": "go build -o bin/tasks ./cmd/tasks",
  "scenarios": {
    "smoke": {
      "steps": [
        { "name": "add a task",
          "run": ["{python}", "{skill}/scripts/drivers/tui_tmux.py", "--cmd", "./bin/tasks",
                  "--step", "{\"wait_for\": \"Tasks\"}",
                  "--step", "{\"keys\": \"a\"}",
                  "--step", "{\"send\": \"Buy milk\"}",
                  "--step", "{\"keys\": \"Enter\"}",
                  "--step", "{\"wait_for\": \"Buy milk\"}",
                  "--step", "{\"capture\": \"after-add\"}",
                  "--step", "{\"keys\": \"q\"}",
                  "--step", "{\"exited\": true, \"code\": 0}"] }
      ]
    }
  }
}
```

### Desktop app (Qt / GTK / native) on Linux, macOS or Windows

UI automation for native desktop apps is fragile, so prefer an **automation seam** (see
`drivers.md`): the app accepts a flag or env var that makes it log key state, write a
ready-marker, or expose a small control socket. Then verification works headless and on
every OS.

```json
{
  "app": "Viewer", "kind": "desktop",
  "requires": ["cmake"],
  "build": "cmake --build build --config Release",
  "display": { "xvfb": "auto" },
  "env": { "QT_LOGGING_RULES": "qml.debug=true", "APP_AUTOMATION": "1" },
  "services": {
    "app": { "cmd": ["{root}/build/viewer", "--automation-port", "47001"],
             "ready": { "log": "automation: listening", "timeout": 30 } }
  },
  "scenarios": {
    "smoke": {
      "needs": ["app"],
      "steps": [
        { "name": "open file via automation seam",
          "http": { "url": "http://127.0.0.1:47001/open?path={root}/tests/sample.png",
                    "json_equals": { "ok": true } } },
        { "name": "window shows image", "http": { "url": "http://127.0.0.1:47001/state",
                    "contains": "\"imageLoaded\":true" } },
        { "name": "screenshot", "run": ["{python}", "{skill}/scripts/drivers/screenshot.py", "main"] },
        { "name": "no QML warnings", "log": { "service": "app", "not_matches": "(?i)qml.*(warning|error)|ReferenceError|TypeError" } }
      ]
    }
  }
}
```

On Linux CI with no display, `"xvfb": "auto"` starts a virtual display. Alternatively Qt
apps can run with `QT_QPA_PLATFORM=offscreen` (no screenshots of the desktop, but the app can
grab its own window through the automation seam).

### Electron

```json
"services": {
  "app": { "cmd": "npx electron . --remote-debugging-port=9222",
           "ready": { "http": "http://127.0.0.1:9222/json/version" } }
},
"scenarios": { "smoke": { "needs": ["app"], "steps": [
  { "run": ["{python}", "{skill}/scripts/drivers/web_playwright.py", "--cdp", "http://127.0.0.1:9222",
            "--step", "{\"expect_text\": \"Projects\"}", "--step", "{\"screenshot\": \"main\"}",
            "--metrics", "main", "--fail-on-console-error"] } ] } }
```

### Windows desktop (WPF / WinForms / WinUI)

Use list-form commands, `{python}`, and an automation driver suited to Windows (see
`drivers.md`: FlaUI or pywinauto). A small Python or PowerShell driver script under
`scripts/drivers/` called from a `run` step keeps the config portable.
