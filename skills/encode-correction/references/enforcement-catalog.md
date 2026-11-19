# Enforcement catalog

Concrete ways to make a mistake impossible (level 1) or automatically detected (level 2), by
ecosystem. Always check what the project **already uses** before adding a tool: a rule in an
existing linter costs almost nothing to maintain, and a new tool costs setup, CI time and
attention.

## Contents

- [Level 1 tactics (any language)](#level-1-tactics-any-language)
- [JavaScript / TypeScript](#javascript--typescript)
- [Python](#python)
- [C# / .NET](#c--net)
- [Java / Kotlin](#java--kotlin)
- [Go](#go)
- [Rust](#rust)
- [C / C++ and Qt / QML](#c--c-and-qt--qml)
- [Shell and config files](#shell-and-config-files)
- [Language-agnostic tools](#language-agnostic-tools)
- [Writing good guard messages](#writing-good-guard-messages)

---

## Level 1 tactics (any language)

| Mistake pattern | Make it impossible by… |
|---|---|
| Mixing up IDs, units, or raw strings | Distinct types: newtypes, branded types, value objects, enums |
| Forgetting a required step (validation, auth, logging) | One entry point that always does it; hide the raw version |
| Calling a dangerous or deprecated helper | Delete it, or make it private/internal |
| Two ways to do the same thing | Delete one; agents copy whichever they saw last |
| Layer violations (UI calls the DB) | Package/module visibility, separate build targets, dependency direction |
| Invalid states (loading + error + data all set) | A discriminated union / sealed class / tagged enum |
| Null / missing values | Non-nullable types, required constructor params, Option/Maybe |
| Wrong thread or process (heavy work on the UI thread) | Separate modules per process/thread with no import path between them |
| Copy-pasted configuration | Generate it from one source |

When a level-1 fix is a big refactor, add a level-2 guard *now* and propose the refactor
as a follow-up.

---

## JavaScript / TypeScript

**Compiler:** `strict: true`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`,
`noImplicitOverride`, `noFallthroughCasesInSwitch`.

**ESLint (most flexible, no plugin required):**

- `no-restricted-imports`: ban modules or specific named imports, with a custom message.
  Use `patterns` for path globs (e.g. ban `../../*` deep relative imports).
- `no-restricted-syntax`: ban any AST shape with an ESLint selector, e.g.
  `"CallExpression[callee.name='setTimeout'][arguments.1.value=0]"`. Very powerful; try it
  before writing a custom rule.
- `no-restricted-globals`, `no-restricted-properties` (e.g. ban `Date.now` outside a clock
  module).
- `@typescript-eslint/no-explicit-any`, `@typescript-eslint/ban-ts-comment`,
  `@typescript-eslint/no-floating-promises`, `@typescript-eslint/switch-exhaustiveness-check`.
- Boundaries: `import/no-restricted-paths` (eslint-plugin-import), `eslint-plugin-boundaries`,
  or **dependency-cruiser** for whole-graph rules ("renderer must not import from main").
- Local custom rules: with flat config you can define a rule inline in a local plugin object;
  no package publishing needed.

**Biome** users: `noRestrictedImports`, `noExplicitAny`, and other lint rules in `biome.json`.

## Python

- **ruff**: `flake8-tidy-imports.banned-api` (TID251) bans modules or attributes with a
  message; `banned-module-level-imports`; `TID252` relative-import policy; many bug-pattern
  rules (B, PL, PERF, etc.).
- **mypy --strict** / **pyright strict**: `disallow_any_explicit`, `warn_unreachable`;
  `typing.NewType` / `Literal` / `Enum` for level-1 fixes.
- **import-linter**: layered and forbidden-import contracts ("domain must not import
  infrastructure") checked in CI.
- Architecture tests: a pytest test that walks modules with the `ast` module and asserts
  rules. Handy when no linter rule exists.

## C# / .NET

- Project settings: `<Nullable>enable</Nullable>`, `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>`
  or targeted `<WarningsAsErrors>`, `<AnalysisLevel>latest-recommended</AnalysisLevel>`.
- `.editorconfig`: raise any IDE/CA rule to `error`
  (`dotnet_diagnostic.CA2007.severity = error`).
- **Microsoft.CodeAnalysis.BannedApiAnalyzers**: list banned symbols in `BannedSymbols.txt`
  with a message (`M:System.DateTime.get_Now;Use IClock`). This is the go-to for "don't call X".
- Architecture tests: **NetArchTest.Rules** or **ArchUnitNET** inside the test project
  ("types in *.Domain must not depend on *.Infrastructure").
- Level 1: `internal` + separate assemblies, `sealed` records, required members, `readonly`
  structs for value objects. A custom Roslyn analyzer is level 2 at its strongest, worth it
  for rules that matter a lot.

## Java / Kotlin

- **ArchUnit** (Java/Kotlin) or **Konsist** (Kotlin) for architecture tests.
- **Error Prone** (bug patterns, custom checks), **Checkstyle** (`IllegalImport`,
  `RegexpSingleline`), **PMD**.
- **detekt** (Kotlin): `ForbiddenImport`, `ForbiddenMethodCall`, `ForbiddenAnnotation`.
- Level 1: JPMS modules or Gradle module boundaries (`implementation` vs `api`), sealed
  interfaces, `@JvmInline value class`.

## Go

- Level 1: `internal/` directories are enforced by the compiler; package boundaries; defined
  types (`type UserID string`).
- **golangci-lint** with `depguard` (banned imports), `forbidigo` (banned identifiers by
  regex, with messages), `gocritic`, `errorlint`, `exhaustive`.
- `go vet` analyzers; custom analyzers via `golang.org/x/tools/go/analysis` when needed.

## Rust

- `[lints]` table in `Cargo.toml` (e.g. `unsafe_code = "forbid"`), or `#![deny(...)]`.
- **clippy.toml**: `disallowed-methods`, `disallowed-types`, `disallowed-macros`, each with
  a `reason` that's shown in the error.
- **cargo-deny** for banned crates and licenses.
- Level 1: newtypes, private fields + constructors, `#[non_exhaustive]`, typestate patterns,
  module privacy.

## C / C++ and Qt / QML

- Compiler: `-Wall -Wextra -Werror` (or `/W4 /WX`), `-Wconversion`, `-Wshadow`.
- `#pragma GCC poison <identifier>` (GCC/Clang): makes any later use of an identifier a hard
  compile error. A cheap level-1 for banned functions (`strcpy`, `sprintf`).
- **clang-tidy**: `bugprone-*`, `cppcoreguidelines-*`, `modernize-*`,
  `bugprone-unsafe-functions`, `misc-include-cleaner`; run via `run-clang-tidy` in CI with
  `WarningsAsErrors`.
- Level 1: `= delete` unwanted overloads/conversions, `explicit` constructors, strong typedef
  wrappers, `enum class`, CMake `PRIVATE` linkage to hide dependencies between targets.
- **Qt**: `QT_NO_CAST_FROM_ASCII`, `QT_NO_CAST_TO_ASCII`, `QT_NO_KEYWORDS`,
  `QT_DISABLE_DEPRECATED_UP_TO`; **clazy** for Qt-specific checks (detaching containers,
  wrong connect usage, etc.).
- **QML**: `qmllint` with warning levels set in `.qmllint.ini` (unqualified access, missing
  types, deprecated APIs); treat its output as errors in CI.

## Shell and config files

- **shellcheck** for scripts; set `set -euo pipefail` as a convention (and guard for it).
- JSON/YAML: a JSON Schema checked in CI (e.g. `check-jsonschema`), so invalid config can't
  be committed.
- Dockerfiles: **hadolint**.

## Language-agnostic tools

| Tool | Good for | Notes |
|---|---|---|
| `guard.py` (this skill) | Any "never write X here" rule as a regex | Zero dependencies; has baselines; least precise (text, not syntax) |
| **ast-grep** (`sg scan`) | Syntax-aware search-and-ban rules in YAML, many languages | Precise; fast; supports fixes |
| **semgrep** | Pattern rules with metavariables, many languages | Large existing rule library |
| **pre-commit** framework | Running any of the above before commit | Pair with the same check in CI; hooks can be skipped locally |
| CI script | Anything you can express as "run X, fail if Y" | Last resort, but always available |
| **Ratchet** | A number that must never get worse: coverage, warning count, bundle size, `any` count, guard baseline size | Commit the current value as a baseline file; CI fails if it regresses, and the baseline is raised when it improves. Feature PRs must not lower it |

Regex guards trade precision for universality. If a regex rule starts needing lookaheads to
avoid false positives, move it to ast-grep/semgrep or the language's own linter.

## Writing good guard messages

The person, or more likely the agent, who hits the guard reads only the message. Make it an
instruction:

- Bad: `Forbidden pattern.`
- Bad: `Don't use fetch.`
- Good: `Use apiClient from src/api/client.ts instead of fetch(). It adds auth refresh and retries.`
- Good: `Heavy work isn't allowed in renderer/. Move it to worker/ and call it via the job queue (see worker/README.md).`

Include: what to do instead, where the blessed example lives, and the reason in a few words.
