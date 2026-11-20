# encode-correction

Turns "don't do that again" into something in the project that stops the mistake from
happening again.

Skill file: [skills/encode-correction/SKILL.md](../skills/encode-correction/SKILL.md).
Back to the [overview](../README.md).

## What it solves

You correct an agent. It fixes the code and apologizes. The next session starts with a
blank memory and makes the same mistake, because the correction lived only in a chat.

Fixing the code repairs one change. This skill makes the correction part of the project,
so it protects every later change, whoever or whatever writes it.

## How it works

The skill ranks the ways to enforce a rule, strongest first. It calls this the
enforcement ladder.

| Level | How | Why it ranks here |
| --- | --- | --- |
| 1. Impossible | Types, module boundaries, deleting the wrong option | The mistake cannot be written |
| 2. Detected | A linter rule, a test, a CI check, the bundled `guard.py` | It fails loudly every time |
| 3. Guided | A rule in `AGENTS.md` or a skill | Usually followed, sometimes skipped |
| 4. Reviewed | A style guide, human review | Depends on someone noticing |

It always tries the highest level first, and says why when it settles for a lower one.

1. **State the correction** as one sentence with a scope and a reason: "In this place, do
   or don't do this, because of that."
2. **Fix the code** that prompted it.
3. **Find the same mistake elsewhere.** Agents copy what they see, so existing copies are
   often how the mistake got made.
4. **Climb the ladder.** It first checks whether the rule is already written somewhere.
   If it is and the mistake still happened, writing it again or louder will not help. The
   rule needs stronger enforcement.
5. **Deal with existing copies.** A few get fixed now. Many get frozen with a baseline,
   so the check passes on today's code and fails on anything new.
6. **Prove the guard works** by bringing the mistake back for a moment and watching the
   check fail.
7. **Log it** in `.agent/corrections.md`.

Once a check enforces a rule, the skill deletes the written version of it. Shorter
instruction files get read.

`guard.py` is a small pattern checker that needs only Python 3 and works for any
language. Its rules live in `.agent/guards.json`.

## How it connects

- [garden](garden.md) reads the corrections log to see where mistakes cluster, and uses
  this skill's ladder and `guard.py` when it adds guards.

The two work as a pair. `encode-correction` reacts to one mistake at the moment you point
it out. `garden` goes looking for mistakes nobody has pointed out yet.

## How to ask for it

Correct the agent: "don't do that again", "we never do it this way". Or ask directly:
"add a guard so this can't happen again".
