# typescript-best-practices

A short list of TypeScript rules that an agent applies whenever it reads or edits a `.ts`
or `.tsx` file.

Skill file:
[skills/typescript-best-practices/SKILL.md](../skills/typescript-best-practices/SKILL.md).
Back to the [overview](../README.md).

## What it solves

TypeScript lets you tell the compiler to stop checking. `any` turns types off. An `as`
cast says "trust me". Agents reach for both when the types get hard, and the bug shows up
later, at runtime, far from where it was caused.

This skill pushes the other way. Shape the types so the wrong value cannot be written,
check outside data once where it comes in, and let the compiler do the rest.

## How it works

The skill is one table of rules, with examples in a reference file. Its file lists the
paths `**/*.ts` and `**/*.tsx`, so an agent tool that supports path rules loads it
whenever such a file is opened.

The main rules:

- **Model variants as a union with a `kind` field,** so impossible combinations cannot be
  represented.
- **Brand simple values.** A user id and an order id are both strings, and a brand stops
  one from being passed as the other.
- **Outside data is `unknown`,** never `any`. Parse it once at the boundary, with the
  project's schema library, into a named type.
- **No `as` casts** except right after validation. Prefer `satisfies`.
- **Make switches exhaustive,** so adding a new variant produces a compiler error where it
  is not handled.
- **Derive types** from what exists before declaring new ones.
- **Do not mock what you can run.** Test against the real thing where possible.
- **Log with structure.** No `console.log` in shipped code.

## How it connects

It works on its own. No skill in this repository calls it.

- [coding-standards](coding-standards.md) states the same two ideas for any language,
  under its headings "Type system discipline" and "Boundary discipline". This skill is
  how they look in TypeScript.
- [csharp-modernization](csharp-modernization.md) is the other language skill here.

The skill file names two "principle skills", `type-system-discipline` and
`boundary-discipline`. They are not part of this repository.

## How to ask for it

Usually you do not need to, because it loads with `.ts` and `.tsx` files. Where it does
not, say "follow typescript-best-practices in this file".
