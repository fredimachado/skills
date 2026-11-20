# csharp-modernization

Helps an agent write and update C# with features from C# 9 through C# 15, without
breaking the build or quietly changing behavior.

Skill file:
[skills/csharp-modernization/SKILL.md](../skills/csharp-modernization/SKILL.md). Back to
the [overview](../README.md).

## What it solves

C# gains features every year, and which ones you can use depends on the project's
settings. An agent left alone goes wrong in two directions. It uses syntax the project
cannot compile, or it sticks to old syntax when a newer feature would be clearer.

The second risk is harder to see. Some modern rewrites compile and still change what the
program does. A different overload gets picked, an expression runs at a different time, a
lock behaves differently.

## How it works

1. **Check the project first.** It reads the target framework, the language version and
   the shared build files, and checks which SDK is selected. If the settings are unclear
   it asks the build system or the compiler directly.
2. **Pick the lowest version that does the job.** A table maps each C# version to its
   default .NET target and to a guide for that version's features. There is one guide per
   version, from C# 9 to C# 15.
3. **Read the guide for the feature** before using it.
4. **Keep behavior in scope.** It checks construction, validation, equality,
   serialization and overload selection wherever the edit touches them. A change to a
   public setter, constructor or operator counts as an API change.
5. **Build and test.** It builds the affected projects and runs the existing tests. Where
   a rewrite could silently change behavior, it adds a focused check.

A second table lists compiler errors that often follow a modernization, each with the
first thing to check.

## How it connects

It works on its own and calls no other skill.

- [modernize-pr](modernize-pr.md) has a similar name and a different job. That skill
  updates an old pull request. This one updates code.
- [typescript-best-practices](typescript-best-practices.md) is the other language skill
  in this repository.

## How to ask for it

"Use csharp-modernization to simplify this class while keeping it compatible with C# 12."
