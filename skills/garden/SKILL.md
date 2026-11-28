---
name: garden
description: Tend a codebase so agents keep copying good patterns instead of bad ones. Finds workarounds, suppressions, swallowed errors, sleeps, disabled tests, competing ways of doing the same thing, and checks whether they're spreading. Then guards against them first and plans cleanup second. Use when the user asks to garden, weed, audit code health, find tech debt or anti-patterns, check what's spreading, prepare a cleanup plan, review "agent slop", or run a periodic codebase health check, even if they don't say "garden".
---

# Garden

Agents extend whatever patterns they see. A clean codebase keeps producing clean code, and a
single workaround (especially one with a comment explaining it) can become the de facto
pattern within weeks. Gardening means finding those weeds early, **stopping their spread
first**, and removing them second.

The output of a gardening pass is a short evidence-based report, proposed or implemented
guards according to the selected mode, and small cleanup tasks. Prefer the smallest fix
that addresses the root cause. Avoid cosmetic churn and speculative rewrites.

## Modes

- **Report** (default, and always in scheduled or unattended runs): scan, analyze, write the
  report, propose guards and tasks. Don't change source code, tests, CI, or enforcement
  rules. Only garden configuration, reports, and requested snapshots may be written.
- **Guard**: report, plus add guards (with baselines) for the top findings. Use when the user
  asks to "stop the bleeding" or approves the proposed guards.
- **Weed**: guard, plus actually do one or more cleanup tasks. Only when the user asks.

If the user requests a strictly read-only audit, create no files. Keep proposed configuration
and the report in the conversation, and omit `--save`.

## Procedure

### 1. Scan

Read the project instructions, architecture, dependency manifests, tests, CI rules, and
representative implementations before judging patterns. Adapt the inspection to the
project's language and tools.

Run the bundled scanner from the repo root (path is wherever this skill is installed):

```bash
python <skill>/scripts/scan.py --since-days 30          # first run: compares with git history
python <skill>/scripts/scan.py --compare-last --save    # later runs: compare with last snapshot
```

It reports built-in signals (workaround markers, suppressions, swallowed errors, sleep-based
waits, disabled tests, debug leftovers, loose types, tests that can't fail, rules that live
only in comments, large files), any project-specific signals, and "families" of competing
implementations, with growth since the comparison point and the files where each signal
grew.

The signals are **hints, not verdicts**. A `sleep` in a retry back-off is fine; a `sleep`
waiting for a UI to render is a candidate for investigation. Read the surrounding code and
callers before judging. Supplement scanner results with searches for stale or misleading
comments, duplicate logic, unnecessary abstractions, and bypassed validation. Before you
call code unused, search the whole tree for its name: tests, fixtures, config, and names
built from strings or loaded at run time.

Find other occurrences of each suspected problem and group them under one finding. Verify
representative file:line locations; scanner matches are not confirmed violation counts.

### 2. Configure families on the first run

"Two ways of doing the same thing" is the hardest weed to spot and one of the most damaging,
because an agent picks whichever version it happened to read. If `.agent/garden.json` doesn't
exist, create it, or propose it in a strictly read-only audit:

1. Look at the dependency manifests (package.json, *.csproj, pyproject.toml / requirements,
   go.mod, Cargo.toml, CMakeLists.txt / vcpkg / conan, pom.xml / build.gradle) and skim the
   source layout.
2. Identify concerns where more than one approach exists or could plausibly creep in: HTTP
   clients, date/time handling, logging, state management, error handling, config access,
   async patterns, test helpers, styling, DI, serialization.
3. Write a family per concern with one regex per alternative. Examples and the full file
   format are in `references/smell-catalog.md`.
4. Add project-specific signals for weeds that came up in `.agent/corrections.md`.

Then re-run the scan. In a strictly read-only audit, use targeted searches to evaluate
proposed families without writing the configuration.

Multiple approaches can serve different requirements or boundaries. Confirm harmful overlap
before recommending consolidation; the existence of two libraries alone is not a finding.

### 3. Gather other evidence

- `.agent/corrections.md`, if present: corrections logged by the `encode-correction`
  skill. Repeated corrections in one area point to a missing guard or a confusing pattern.
- Churn: `git log --since=30.days --name-only --format= | sort | uniq -c | sort -rn | head -20`.
  Weeds in high-churn files spread fastest, because those are the files agents read most.
- Copy sources: templates, examples, base classes, scaffolding scripts, the most recently
  added feature, documentation, and agent instructions. Agents copy "the nearest similar
  thing", so a weed there matters more.
- Feature map drift: if the project has a `verify-*` skill, run its `verify.py run map`
  scenario (or `check-map` and `audit-map`) and include the findings. Recipes quoting UI
  text that no longer exists are weeds too: agents follow them and fail, or "fix" the app to
  match the stale doc. When the map and the app disagree, say which kind it is: **doc
  drift** (the app is right; fix the map), **harness gap** (the app works but the harness
  can't drive it; fix the harness) or **product regression** (the map is right; report it,
  and don't edit the map to match). Also run `verify.py stale-map` and list the features it
  flags (code changed after their map entry). If there are any, add the verify skill's
  *Audit pass* to the cleanup tasks; in Weed mode, do it.
- Duplicate sources of truth: two feature maps, two setup guides, the same instructions in
  several agents' folders (`.claude/`, `.cursor/`, `.agents/`). They drift apart; propose
  merging into one and leaving pointers.
- Existing guards: `.agent/guards.json` and its baseline. Check whether baselined counts are
  shrinking. Report an unchanged baseline as no measured reduction; check history before
  concluding cleanup has stalled.

Separate measured growth from suspected copy risk. Record the comparison period and whether
counts represent scanner matches or reviewed occurrences. If history or a prior snapshot is
unavailable, report the trend as unknown. Renames and changed scan rules can distort counts.

### 4. Triage

Rank findings by **spread risk**, roughly: growth × how copyable × how harmful.

- *Growing* beats *large but stable*: a stable count of 40 is debt; a count that went from
  2 to 9 this month is an infestation.
- *In copy sources or high-churn files* beats *in a dusty corner*.
- *Harmful when copied* (swallowed errors, wrong-thread work, bypassed auth/validation,
  sleeps in tests) beats *cosmetic*.

Lead with the top 3–5 and group remaining findings compactly. Separate confirmed problems
from suggestions. High-impact correctness or security problems remain urgent even if stable.

For each, decide the **blessed path**: the one way it should be done. If the codebase has
no good example yet, that's the first cleanup task: create the example, because agents need
something correct to copy.

### 5. Guard first

For each top finding, propose the strongest practical guard. Implement it only in Guard or
Weed mode. Prefer architecture/API design or types that make the mistake impossible, then
lint/static checks or meaningful tests. Use written guidance when automatic enforcement is
impractical. If the `encode-correction` skill is available, use its relevant workflow in
Guard or Weed mode; its `guard.py` supports baselines to freeze today's violations and fail
only on new ones.

Comments that justify workarounds deserve special attention. Agents cite them as the reason
not to fix the underlying problem. Consider a guard for workaround markers in new code, or a
rule that a workaround needs a linked issue, rather than banning comments altogether.

Preserve useful explanations of intent, external constraints, non-obvious decisions, and
required legal notices. Investigate whether a workaround is still necessary before
recommending its removal. A linked issue alone does not establish that it is justified.

A `shortcut: <limit>, <when to upgrade>` comment records a decision. Leave it while the
code stays inside the limit it names. One that names no trigger, or whose limit the code
has passed, is a finding: nothing will ever prompt anyone to revisit it.

Comments that state a rule ("do not remove", "keep in sync with X", "must match Y") are
guidance pretending to be enforcement. For each one that's about the project's own code,
ask what would make it true by construction: generate one side from the other, a test that
compares the two, a type, a guard. Propose the enforcement in Report mode; implement it in
Guard or Weed mode. Remove redundant comments only in Weed mode, preserving useful rationale.

For ineffective tests, first identify a plausible regression that the assertions miss.
Prefer relevant test-framework lint rules or a narrowly scoped guard with a baseline when
they can detect the problem reliably. Assertion counts or matcher names alone do not prove
a test protects the intended behavior.

### 6. Plan the cleanup

Break cleanup into tasks that each fit in one reviewable PR, covering one module or pattern.
Shrink an existing baseline where applicable; a baseline is not required for every fix.
Order: create missing blessed examples → fix copy sources and high-churn files → everything
else. Include the root cause, files, smallest practical replacement (delete, simplify,
consolidate, or refactor), and how to verify both preserved behavior and prevention of new
occurrences. A lower guard count alone does not prove behavior is correct.

Split a large file or function by job, never by line count, and never into helpers that
exist only to make it shorter.

Cleanup tasks are refactorings. Whoever does one (you, in Weed mode, or a later agent)
should follow the `playbook-refactoring` skill if it's available: pin the behaviour first,
migrate every caller, delete the old path.

### 7. Write the report

Save it to `.agent/garden/reports/YYYY-MM-DD.md` and show a summary, unless the user requests
a strictly read-only audit or an inline report. Use this structure:

```markdown
# Garden report: YYYY-MM-DD

## Summary
<2–3 sentences: overall trend, the one thing that matters most>

## Scope and evidence
<areas inspected and skipped, comparison period, count definitions, uncertainty>

## Spreading (act now)
| Pattern / impact | Count (change) | File:line evidence / spread risk | Blessed path | Guard |
|---|---|---|---|---|

<mark unmeasured trends as unknown; separate suspected spread from measured growth>

## Stable debt (plan)
<short list>

## Competing implementations
<family: alternatives in use → which one wins, migration size>

## Guards added / proposed
<rule id, level, baseline size>

## Cleanup tasks
1. <task>: root cause, files, replacement, behavior verification, prevention check

## Signals reviewed and dismissed
<false positives, so the next pass doesn't re-investigate them>
```

The "dismissed" section keeps future passes from re-flagging legitimate code. Record why
each exception is justified. For permanent whole-file exclusions, consider a narrowly scoped
`exclude_regex` in `.agent/garden.json`; it skips every signal in matching files, so do not
use it to dismiss a single legitimate occurrence. Propose exclusions in read-only audits.

## Running it regularly

Gardening works best as a habit: weekly or every couple of weeks, in report mode, saving a
snapshot each time (`--compare-last --save`) so trends accumulate. Commit `.agent/garden.json`
and the reports; snapshots can be committed or ignored, as the team prefers.
