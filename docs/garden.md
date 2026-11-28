# garden

Looks through a codebase for bad patterns that agents are likely to copy, checks whether
they are spreading, and stops the spread before cleaning up.

Skill file: [skills/garden/SKILL.md](../skills/garden/SKILL.md). Back to the
[overview](../README.md).

## What it solves

Agents write new code by imitating the code around them. In a clean codebase that works
in your favor. But one workaround, especially one with a comment explaining why it is
there, gets copied. A few weeks later it is the normal way to do things.

`garden` finds these early, and it works in a fixed order. Stop the pattern from growing
first, remove it second. A problem that has stopped growing can wait. One that doubles
every month cannot.

## How it works

It runs in one of three modes.

- **Report** is the default. It scans, analyzes and writes a report. It changes no source
  code.
- **Guard** also adds checks for the top findings.
- **Weed** also does some of the cleanup. Only when you ask.

The steps:

1. **Scan.** The bundled `scan.py` counts warning signs: workaround markers (`shortcut:`
   comments included), suppressed warnings, swallowed errors, sleeps used as waits,
   disabled tests, rules that exist only in comments. It compares the counts with an
   earlier point in time. These are hints. A sleep in a retry is fine, so the agent reads
   the code before judging.
2. **Look for competing ways to do one thing.** Two HTTP clients, two date libraries, two
   logging styles. An agent picks whichever it read last.
3. **Gather more evidence.** Which files change most, which files agents copy from, what
   corrections were logged, whether the feature map still matches the app.
4. **Rank by risk of spreading.** Growing beats large but stable. A pattern in a template
   beats one in a forgotten corner. Harmful beats cosmetic.
5. **Decide the blessed path** for each finding, the one way it should be done. If the
   codebase has no good example yet, creating one is the first cleanup task.
6. **Guard first.** Propose the strongest practical check for each top finding.
7. **Plan the cleanup** as tasks small enough for one pull request each. A large file is
   split by job, never by line count.
8. **Write the report** to `.agent/garden/reports/`. It includes the signals that were
   reviewed and dismissed, so the next pass does not chase them again.

It works best as a habit, every week or two, so the trend becomes visible.

## How it connects

- [encode-correction](encode-correction.md) logs corrections that `garden` reads, and
  supplies the ladder of enforcement and the `guard.py` checker that `garden` uses for
  its guards.
- [bootstrap-verification](bootstrap-verification.md) creates the `verify-<app>` skill.
  When a project has one, `garden` runs its map checks and reports entries that no longer
  match the app.

## How to ask for it

"Garden this repo", "audit code health", or "what bad patterns are spreading here?"
