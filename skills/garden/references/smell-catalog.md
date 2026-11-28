# Smell catalog and garden.json

## Contents

- [garden.json format](#gardenjson-format)
- [Family examples by ecosystem](#family-examples-by-ecosystem)
- [Weeds that spread fastest with agents](#weeds-that-spread-fastest-with-agents)
- [Judging built-in signals](#judging-built-in-signals)

---

## garden.json format

`.agent/garden.json` at the repo root. All keys are optional.

```json
{
  "families": {
    "http client": {
      "apiClient (blessed)": "\\bapiClient\\.",
      "raw fetch": "\\bfetch\\(",
      "axios": "\\baxios[.(]"
    },
    "dates": {
      "date-fns (blessed)": "from ['\"]date-fns",
      "moment": "from ['\"]moment['\"]|require\\(['\"]moment",
      "raw Date math": "new Date\\(\\)\\.getTime\\(\\)\\s*[-+]"
    }
  },
  "signals": {
    "string-built-sql": {
      "why": "SQL built by string concatenation. Use the query builder (injection risk, and it gets copied).",
      "patterns": ["(?i)[\"'`]\\s*(?:SELECT|UPDATE|DELETE|INSERT)\\b[^\"'`]*[\"'`]\\s*\\+"],
      "code_only": true
    },
    "snapshot-assertion": {
      "why": "Snapshot assertions. Snapshot updates tend to get approved without being read; prefer asserting the values that matter.",
      "patterns": ["toMatchSnapshot\\(\\)"],
      "path_regex": "\\.test\\.tsx?$"
    }
  },
  "disable": ["debug-leftover"],
  "exclude_regex": ["^docs/", "^scripts/legacy/", "\\.generated\\."],
  "large_file_lines": 800
}
```

- **families**: concern → { alternative label → regex }. The scanner flags a family when
  more than one alternative is in use. Mark the blessed one in its label so reports are
  self-explanatory.
- **signals**: extra project-specific weeds. `patterns` is a list of regexes; matches from
  all patterns are summed. The optional `path_regex` limits a signal to files whose
  repo-relative path matches it (test files, one layer). For a hard "never write X here"
  rule, prefer a guard with `include` globs (encode-correction's `guard.py`); signals are
  for watching trends.
- **disable**: built-in signal names to turn off.
- **exclude_regex**: file path regexes to skip entirely (generated code, vendored code,
  deliberate legacy areas).
- **large_file_lines**: threshold for the large-files list.

Regexes are Python syntax; escape backslashes for JSON (`\\b`, `\\.`).

## Family examples by ecosystem

Pick the ones relevant to the project; don't add families for concerns the project doesn't
have.

**Web / TypeScript:** HTTP (fetch / axios / ky / custom client), dates (Date / date-fns /
dayjs / moment / luxon), state (Redux / Zustand / context / signals / ad-hoc module state),
styling (CSS modules / Tailwind / styled-components / inline styles), forms, data fetching
(React Query / SWR / useEffect+fetch), validation (zod / yup / hand-written), test
selectors (data-testid / role queries / CSS selectors).

**Python:** HTTP (requests / httpx / urllib / aiohttp), config (env reads scattered vs. a
settings object), logging (logging / print / structlog / loguru), paths (os.path /
pathlib), data models (dict / dataclass / pydantic / attrs), async vs. threads.

**C# / .NET:** DI (constructor injection vs. service locator / `new`), logging (ILogger /
Console / Serilog static), HTTP (IHttpClientFactory / `new HttpClient`), data access (EF /
Dapper / raw ADO), time (`DateTime.Now` vs. `TimeProvider`/clock abstraction), mapping
(manual / AutoMapper / Mapster), async (`.Result` / `.Wait()` vs. await).

**Java / Kotlin:** HTTP clients, null handling (Optional / nullable / annotations), logging
facades, coroutines vs. callbacks vs. RxJava.

**Go:** errors (`fmt.Errorf("%w")` / pkg/errors / string errors), logging (log / slog /
zap / zerolog), config, context propagation.

**Rust:** errors (anyhow / thiserror / Box<dyn Error> / unwrap), async runtimes, logging
(log / tracing).

**C++ / Qt / QML:** strings (QString / std::string / char*), containers (Qt / STL), memory
(raw new / unique_ptr / QObject parent ownership), signals (new-style connect / SIGNAL()
macros / lambdas), threading (QThread subclass / moveToThread / QtConcurrent / std::thread),
QML property access (qualified / unqualified), logging (qDebug / qCDebug categories /
std::cout).

**Terminal apps / CLIs:** argument parsing (one library vs. hand-rolled), output (structured
writer vs. scattered prints), colors/TTY detection, exit codes.

## Weeds that spread fastest with agents

These deserve top priority when found, because agents copy them most readily:

1. **Justified workarounds.** A hack with a comment explaining why. Agents cite the comment
   as precedent and skip fixing the root cause.
2. **Swallowed errors.** An empty catch becomes "how errors are handled here".
3. **Sleep-based synchronization**, especially in tests and UI code.
4. **Suppression comments.** Once one `@ts-ignore` / `# type: ignore` / `#pragma warning
   disable` exists, agents treat suppressing as an acceptable fix.
5. **Competing implementations.** Overlapping HTTP clients, date libraries, or state stores
   with no clear selection rule. Check whether they serve distinct requirements before
   recommending consolidation.
6. **Wrong-layer calls.** UI calling the DB, renderer doing heavy work, domain code
   reading env vars.
7. **Giant files.** Agents add to whatever file they're in; big files keep getting bigger.
8. **Duplicated docs and maps.** The same procedure or feature map in two places (often one
   per agent tool). Each copy drifts differently, and agents follow whichever they find.
9. **Tests that miss the intended failure.** Weak assertions or expected values computed by
   the code under test can leave regressions undetected. Assertions such as "was called" or
   "didn't throw" can be meaningful when they express the actual contract. Identify the
   behavior the test should protect, then ask whether a plausible broken implementation
   would still pass. Do not classify tests by matcher names alone.
10. **Rules that live only in comments.** "Do not remove", "keep in sync with X", "must
    match the enum in Y". Nothing enforces them, they go stale, and agents either obey a
    stale one or miss a live one. Each is a candidate for the `encode-correction` ladder.

## Judging built-in signals

| Signal | Usually fine when… | A weed when… |
|---|---|---|
| workaround-marker | The external constraint still exists and the workaround is necessary and scoped; a `shortcut:` comment names its limit and when to upgrade, and the code is still inside that limit | The constraint is gone, or the workaround spreads beyond it; an issue link alone proves neither; a `shortcut:` comment names no trigger, or the code has passed its limit |
| suppression | Narrow, with a reason, at a genuine boundary (generated code, FFI) | Blanket, unexplained, or in business logic |
| swallowed-error | Deliberately ignored with a comment saying why (cleanup on shutdown) | Anywhere the error could matter |
| sleep-sync | Retry back-off, rate limiting, animation timing | Waiting for something to "be ready" |
| disabled-test | Linked to an issue with a date | Skipped with no explanation, or flaky test "fixed" by skipping |
| debug-leftover | CLI output that is the product | Diagnostics left behind |
| loose-type | At a typed/untyped boundary, immediately narrowed | Spread through internal code |
| vacuous-test | The assertion protects the actual contract or is a precondition followed by a behavior check | A plausible regression in the intended behavior would pass all assertions |
| constraint-comment | It describes something the project can't change (a vendor quirk, a protocol, a generated file), or it's user-facing text | It states a rule about the project's own code that a type, test or guard could enforce |
| large file | Generated, or a data table | Hand-written logic that keeps growing. Split it by job, never by line count |
