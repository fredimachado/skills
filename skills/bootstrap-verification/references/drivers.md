# Choosing how to drive and observe each kind of app

## Contents

- [Principles](#principles)
- [The automation seam](#the-automation-seam)
- [Web apps](#web-apps)
- [Services and APIs](#services-and-apis)
- [CLIs](#clis)
- [Terminal UIs and interactive CLIs](#terminal-uis-and-interactive-clis)
- [Desktop apps](#desktop-apps)
- [Electron and other Chromium shells](#electron-and-other-chromium-shells)
- [Mobile](#mobile)
- [Performance evidence by platform](#performance-evidence-by-platform)

---

## Principles

1. **Observe through the most stable interface available.** In rough order of stability:
   the app's own API or automation seam → structured logs → accessibility tree → DOM/selectors →
   pixels. Screenshots are great evidence for humans but poor assertions.
2. **Wait for conditions, never for time.** Every readiness check and every UI wait should
   be "until X is true, with a timeout", not `sleep`.
3. **Fail loudly on hidden errors.** Console errors, unhandled exceptions, QML warnings,
   500s in the server log: check for them in every scenario, not just when looking.
4. **Make it headless-capable.** Agents often run without a display. Plan for Xvfb, headless
   browsers, offscreen platforms, or a seam that doesn't need a screen.
5. **Put the procedure in code.** Anything the agent would otherwise improvise each session
   (start order, ports, test data, login) belongs in the config or a driver script.

## The automation seam

For any app that's hard to drive from outside (native desktop, games, embedded UIs, complex
canvases), the most reliable approach is to add a small, test-only entry point **to the app
itself**:

- A flag/env var (`--automation`, `APP_AUTOMATION=1`) that's off by default.
- When on, the app does one or more of:
  - logs a clear **ready marker** ("automation: ready") once the main window/state is ready;
  - logs key **state transitions** in a parseable form;
  - exposes a tiny local **control endpoint** (HTTP on 127.0.0.1, a local socket, or
    stdin/stdout commands) to trigger actions ("open file", "navigate to view X") and dump
    state as JSON ("which view is visible, how many items, last error");
  - can **grab its own window** to a PNG (e.g. Qt's `QQuickWindow::grabWindow()` /
    `QWidget::grab()`), which works even offscreen.

It's a few dozen lines, works on every OS and in CI, and gives assertions that don't break
when a button moves. Propose it to the user when the app is a desktop or otherwise
hard-to-automate app; don't add it without agreement, since it changes the product's code.

## Web apps

- **Driver:** Playwright (`scripts/drivers/web_playwright.py`, Python). Selectors: prefer
  roles and accessible names (`role=button[name='Save']`) or test ids over CSS chains.
- **Evidence:** screenshots, console errors, network failures, Playwright trace
  (`--trace`), Chromium performance trace (`--perf-trace`), heap snapshot
  (`--heap-snapshot`), navigation/paint timings and CDP metrics (`--metrics`).
- If the project already uses Playwright (Node) or Cypress tests, call that test runner from
  `run` steps instead: one scenario per feature targeting its specs, plus one for the full
  suite. Don't introduce a second browser tool.
- Start dev servers with a fixed port and "strict port" so the URL is predictable.
- **Never reuse a server you didn't start.** Playwright's common
  `reuseExistingServer: !process.env.CI` will happily test whatever is on that port (another
  branch, a stale build). Run scenarios with `CI=1`, or give the harness its own port.
- Playwright starts **every** `webServer` in its config for any run, even a single spec. If
  one of them is a production build + preview, every feature scenario pays for a build. Note
  it in *Gotchas*, or propose making the extra server conditional.
- Test runners pin a browser build. In restricted networks the download can fail; check for
  the browser in `doctor`, and document `npx playwright install chromium`.
- **Live drive CLI.** For exploratory proofs ("show me this works"), a small stateful CLI
  pays off: `launch` (isolated server on its own port + browser with its own profile, PIDs
  recorded in an instance file), `doctor` (refuses unless everything recorded is alive and is
  the expected app), `browser <action>` (goto / click / fill / assert / storage / snapshot /
  screenshot by role and accessible name), and `cleanup` (kills the recorded process trees).
  It complements the test suite: tests guard regressions, the CLI lets an agent look.
- On Windows, browsers can outlive their parent process. Clean up by process tree and by
  profile path, not by process name.

## Services and APIs

- **Driver:** the `http` step (built in), or a `run` step with `curl`/a client script for
  complex flows (auth tokens, multi-step).
- **Dependencies:** start databases/queues as services (`docker compose up db` with a
  `port` readiness check) or use the project's existing test containers setup.
- **Evidence:** responses (saved automatically), service logs, a `log` step asserting no
  errors were logged during the scenario.
- **Seed data:** a `run` step that loads fixtures at the start makes scenarios repeatable.

## CLIs

- **Driver:** the `run` step: exit codes, stdout/stderr checks, `stdin` for piped input.
- **Golden files** (`stdout_golden`) are the most valuable check for CLIs: they catch any
  output change. Use `normalize` for timestamps, durations, absolute paths, and run
  `--update-golden` deliberately when output changes on purpose (and review the diff).
- Test error paths too: bad arguments, missing files, permission errors, and the exit code
  for each.

## Terminal UIs and interactive CLIs

- **Driver:** `scripts/drivers/tui_tmux.py` runs the app in a private tmux server with a
  fixed terminal size, sends keys, waits for text, captures screens as text files.
  Text captures are diffable, which makes them better evidence than images.
- **Windows:** tmux isn't available natively; run inside WSL, or use a pty library
  (`pywinpty`) or the app's non-interactive mode for checks.
- **Alternatives:** `pexpect` (Python, POSIX) for REPL-style line-based apps; framework test
  harnesses where they exist (Textual's `Pilot`, Bubble Tea's `teatest`, Ratatui's
  `TestBackend`), which are faster and more precise than driving a real terminal.
- Set `TERM`, `COLUMNS`/`LINES`, and disable color (`NO_COLOR=1`) if color codes make
  assertions brittle.

## Desktop apps

Choose in this order:

1. **The automation seam** (above). Most reliable on every OS.
2. **The UI framework's own test tools**, run as a `run` step:
   - Qt Widgets: Qt Test (`QTest::mouseClick`, `QSignalSpy`); Qt Quick: Qt Quick Test
     (`qmltestrunner`, `TestCase` + `SignalSpy`); commercial: Squish.
   - GTK: `dogtail` (AT-SPI), or GTK's test utilities.
   - WPF/WinForms/WinUI: **FlaUI** (C#) or **pywinauto** (Python) via UI Automation;
     WinAppDriver/Appium for WebDriver-style tests.
   - macOS AppKit/SwiftUI: XCUITest; AppleScript/System Events for simple flows.
   - .NET MAUI / Avalonia: Appium; Avalonia has a headless test platform.
   - Flutter desktop: `integration_test` + `flutter drive`.
3. **Accessibility-tree automation** (AT-SPI on Linux, UI Automation on Windows, AX on
   macOS): stable if the app sets accessible names; useful for checking what's on screen.
4. **Pixels**: `scripts/drivers/screenshot.py` for evidence; avoid image comparison as the
   main assertion unless rendering is the feature.

**Headless on Linux:** set `"display": {"xvfb": "auto"}` (needs the `Xvfb` package) so
services and drivers share a virtual display. Qt also supports `QT_QPA_PLATFORM=offscreen`.

**Logs as evidence:** enable framework diagnostics in the scenario env, e.g.
`QT_LOGGING_RULES`, `QT_FATAL_WARNINGS=1` (makes Qt warnings fatal, which is strict but
effective), `G_DEBUG=fatal-warnings` for GTK, and assert on them with a `log` step.

## Electron and other Chromium shells

Start the app with `--remote-debugging-port=9222`, wait for
`http://127.0.0.1:9222/json/version`, then use `web_playwright.py --cdp http://127.0.0.1:9222`.
Everything from the web section applies, including traces and heap snapshots. Keep
main-process checks (logs, IPC) separate from renderer checks. Main-process slowness doesn't
show up in renderer traces.

## Mobile

Out of scope for the bundled drivers. Typical choices: Appium, Maestro, Detox (React
Native), Espresso/XCUITest, `flutter drive`. Call them from `run` steps so they still produce
evidence in the standard place.

## Performance evidence by platform

| Platform | Measure | Tools |
|---|---|---|
| Web / Electron renderer | Load, long tasks, layout, memory | `web_playwright.py --metrics --perf-trace --heap-snapshot`, Lighthouse CLI |
| Node | CPU, heap | `node --cpu-prof`, `--heap-prof`, clinic.js |
| Python | CPU, memory | `py-spy record`, `cProfile`, `tracemalloc`, scalene |
| .NET | CPU, GC, allocations | `dotnet-counters`, `dotnet-trace`, BenchmarkDotNet |
| JVM | CPU, GC | JFR (`-XX:StartFlightRecording`), async-profiler |
| Go | CPU, heap | `pprof` (`go test -cpuprofile`, net/http/pprof) |
| Rust / C / C++ | CPU, memory | `perf`, `heaptrack`, `valgrind --tool=massif`, Instruments (macOS), WPR/WPA (Windows) |
| Qt / QML | Frame times, bindings | QML Profiler (`-qmljsdebugger`), `QSG_RENDER_TIMING=1`, `QT_LOGGING_RULES=qt.scenegraph.time.*=true` |
| CLI | Wall time | `hyperfine` (warmups, repeated runs, stats) |
| Services | Latency, throughput | `wrk`, `k6`, `hey`, `oha` |

Whatever tool you use, have it write a flat JSON of numbers to `{run_dir}/metrics/NAME.json`
so `verify.py compare` and `budgets` work the same way across platforms.
