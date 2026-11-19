---
name: encode-correction
description: Turn a correction of the agent into a permanent fix in the project so the same mistake can't happen again. Use whenever the user corrects your work, rejects an approach, says "don't do that again", "stop doing X", "we never do it this way", "remember that…", "you keep making this mistake", or when a reviewer flags something an agent got wrong. Also use when the user asks to add a lint rule, guard, convention or project rule because of agent behaviour, or when a code comment states a rule nothing enforces ("do not remove", "keep in sync with…"). Prefer this over just fixing the code and moving on, because fixing the output repairs one change while encoding the correction protects every future change.
---

# Encode correction

A correction that only lives in a chat is lost when the session ends. The next agent, or the
same one with a fresh context, will make the same mistake. This skill turns each correction
into something durable, and pushes it as **high up the enforcement ladder as is practical**.

## The enforcement ladder

From strongest to weakest:

| Level | Mechanism | Why it ranks here |
|---|---|---|
| 1. Impossible | Types, module boundaries, API shape, data structures, deleting the wrong option | The mistake can't be expressed, so nobody has to remember anything |
| 2. Detected | Compiler flags, linters, analyzers, architecture tests, CI checks, `scripts/guard.py` | Fails loudly and automatically, every time, for humans and agents alike |
| 3. Guided | Project rules (AGENTS.md / CLAUDE.md), skills, review-bot prompts | Usually followed, but an agent can skip or forget them |
| 4. Reviewed | Style guide, human code review | Depends on a person noticing; collapses at high PR volume |

Always try the levels in order. Dropping a level is fine when there's a real reason, but say
what the reason was. "Writing a lint rule felt like effort" is not a reason; "the rule needs
semantic knowledge no available linter has" is.

## Procedure

### 1. State the correction precisely

Write one sentence in the form: **"In <scope>, <do / don't do> <thing>, because <reason>."**

- Get the *scope* right. "Never use `any`" and "never use `any` in `src/domain/`" are
  different rules. If the user's intent is ambiguous, ask once.
- Capture the *reason*. Without it, future agents (and humans) can't judge edge cases, and the
  rule will eventually get deleted as "arbitrary".
- Separate the general rule from this one instance. The user saying "don't put that query in
  the controller" probably means "data access goes through repositories", not "this specific
  query lives elsewhere".

### 2. Fix the instance

Fix the code that prompted the correction first, so the work in hand is correct.

### 3. Find existing violations

Search the codebase for other occurrences of the same mistake (grep, ast-grep, the
project's linter). Agents copy what they see, so existing violations are exactly how the
mistake got made. Count them; the count shapes step 5.

### 4. Climb the ladder

**Level 1, can it be made impossible?** Ask:

- Can a type make the wrong thing unrepresentable? (branded/newtype IDs, enums instead of
  strings, non-nullable types, a `Result` type instead of exceptions)
- Can a module boundary or visibility rule hide the wrong option? (make it internal/private,
  move it behind a facade, don't export it)
- Can the API shape force the right path? (a builder that requires the field, one function
  instead of two near-identical ones, removing an overload)
- Can the wrong option just be deleted? (the deprecated helper, the second HTTP client)

If yes and the change is small, do it. If it's a larger refactor, propose it to the user
with a short plan, and still add a level-2 guard now so the problem stops growing while the
refactor waits.

**Level 2, can it be detected automatically?** Prefer, in this order:

1. A built-in compiler or linter setting the project already uses (cheapest to maintain).
2. A configured rule in an existing tool (e.g. a restricted-import rule, a banned-API list).
3. An architecture/dependency test in the project's test framework.
4. A structural search rule (semgrep / ast-grep) if the project already has one of them.
5. The bundled `scripts/guard.py` pattern guard, which needs nothing but Python 3 and works
   for any language. Use it when nothing above fits.

Read `references/enforcement-catalog.md` for concrete options per ecosystem (JS/TS, Python,
C#/.NET, Java/Kotlin, Go, Rust, C/C++, Qt/QML, shell, and language-agnostic tools).

Make sure the check actually runs: wire it into the existing lint/test command and CI. A
rule that nothing runs is level 4 wearing a level-2 costume. Write the error message for the
reader who triggers it, usually an agent: say what to do instead and why, in one line.

**Level 3, guidance.** Only when levels 1–2 aren't practical (the rule needs judgment, e.g.
"prefer composition here", "name things after the domain, not the UI"). Add the smallest
possible rule to the project instruction file (AGENTS.md, CLAUDE.md or equivalent; use the
one the project already has) or to the most relevant skill. Write it as the one-sentence
rule from step 1, including the reason. Don't pad the file: a long rules file gets skimmed.

A rule that needs judgment is easy to agree with and still break, so give it **one concrete
example of the failure**: the code or wording that was wrong, and what it should have been.
An agent matches its draft against an example far more reliably than against a principle.

Level 3 is also the right *complement* to levels 1–2 when the guard's error alone wouldn't
tell an agent what the right pattern is. Then add a one-line pointer to the blessed example.

**Delete what the guard replaces.** Once a level 1–2 mechanism enforces a rule, remove the
written version of that rule from the instruction file, and any "do not…" comment in the
code that said the same thing. The guard's message carries it now. Text that duplicates a
guard drifts away from it, and every line removed makes the remaining rules more likely to
be read.

### 5. Handle existing violations

- **Few (roughly ≤ 10) and safe to change:** fix them now, in the same change.
- **Many, or risky:** don't block on cleanup. Make the guard pass on today's code and fail on
  anything *new*:
  - `guard.py` has built-in baselines (`python scripts/guard.py baseline`).
  - Most linters support per-file ignores or baseline files; use those.

  Then record the cleanup as a follow-up task. The point is to **stop the bleeding first**:
  a frozen problem doesn't spread; a growing one does.

### 6. Prove the guard works

Before claiming it's done:

- Temporarily reintroduce the mistake (or write a fixture) and confirm the check fails with
  the intended message.
- Run it on the real codebase and confirm it passes (or that only baselined violations remain).
- Revert the temporary change.

A guard that has never been seen failing might not work at all.

**Level 3 has no check that fails**, so it's the level most likely to be silently ignored.
For a written rule that matters, and where the tooling allows it, test it the same way:
give a fresh agent session (or subagent) a small, ordinary task that would naturally lead
to the mistake, without mentioning the rule or that it's a test. If it still makes the
mistake, the rule isn't being read or isn't clear: move it somewhere more prominent, sharpen
the example, or reconsider level 2. If you can't run this, say in the report that the rule
is unproven.

### 7. Log it

Append an entry to `.agent/corrections.md` in the repo (create it if missing). This log is
what the `garden` skill and humans use to spot recurring problem areas.

```markdown
## YYYY-MM-DD: <short rule name>
- Rule: In <scope>, <do / don't do> <thing>, because <reason>.
- Level: 1 | 2 | 3 (and why higher levels weren't used, if applicable)
- Enforced by: <file / rule id / test name>
- Proven: <how the guard was seen to fail, or "unproven" for an untested level-3 rule>
- Existing violations: <n fixed> fixed, <n baselined> baselined
- Follow-up: <task or "none">
```

### 8. Report back

Tell the user, briefly: the rule, the level chosen and what enforces it, whether you saw it
fail (or that it's an unproven level-3 rule), how many existing violations were fixed or
frozen, any written rule you deleted because the guard replaces it, and any follow-up that
needs their decision (such as a level-1 refactor you proposed but didn't do).

## Using guard.py

`scripts/guard.py` is a zero-dependency, language-agnostic pattern guard. Rules live in
`.agent/guards.json` at the repo root:

```json
{
  "rules": [
    {
      "id": "no-direct-fetch",
      "pattern": "\\bfetch\\(",
      "include": ["src/**/*.ts", "src/**/*.tsx"],
      "exclude": ["src/api/client.ts", "**/*.test.ts"],
      "message": "Use apiClient from src/api/client.ts. It handles auth, retries and errors.",
      "reason": "Raw fetch calls skipped auth refresh and caused silent 401s."
    }
  ]
}
```

Commands, run from the repo root, with the path to wherever this skill is installed:

```bash
python <skill>/scripts/guard.py check            # exit 1 on any non-baselined violation
python <skill>/scripts/guard.py check --rule ID  # one rule only
python <skill>/scripts/guard.py baseline         # freeze current violations
python <skill>/scripts/guard.py list             # show rules + violation counts
python <skill>/scripts/guard.py test-rule ID FILE  # show matches of one rule in one file
```

Per-rule options: `pattern` (Python regex), `include` / `exclude` (glob lists, `**`
supported), `multiline` (bool), `ignore_case` (bool), `message`, `reason`, `severity`
(`error` or `warn`; warnings never fail the run). The baseline is stored in
`.agent/guards-baseline.json` and is keyed by file + matched text, so it survives line
shifts but catches new copies.

Because the guard should run in CI without depending on where skills are installed, it's
usually best to **copy `guard.py` into the repo** (e.g. `tools/guard.py`) the first time
you use it, and call that copy from the lint script and CI.

## Things to avoid

- Writing a rule into AGENTS.md when a one-line linter setting would enforce it.
- Leaving the written rule (or a "do not remove" comment) in place after a guard enforces
  the same thing.
- Rules without reasons. They get deleted, ignored, or applied too broadly.
- Guards with vague messages ("forbidden pattern"). The message is the agent's instructions.
- Blocking the user's actual task on a large cleanup. Guard first, clean later.
- Encoding a one-off preference as a project rule. If the correction was about *this* change
  only ("not now, keep it simple for the demo"), fix the instance and skip steps 3–7.
