# bootstrap-verification

Sets up, once per project, a way for agents to build, run and check your application
themselves. The result is a new skill in your project named `verify-<app>`.

Skill file:
[skills/bootstrap-verification/SKILL.md](../skills/bootstrap-verification/SKILL.md). Back
to the [overview](../README.md).

## What it solves

An agent usually cannot see your running application. So it says "done" because the unit
tests pass, or it improvises a one-off script that the next agent will write again,
differently. You end up checking every change by hand.

This skill gives agents one repeatable command that starts the real application, uses it,
and saves evidence of what happened. With that in place you can trust "it works" a good
deal more.

## How it works

It creates four things in your project:

- `verify.py`, a script that builds the app, starts its services, waits until they are
  ready, runs scenario steps, stops everything and saves the evidence. It needs only
  Python 3.
- `verify.config.json`, the part specific to your app: the build command, the services,
  the scenarios.
- `feature-map.md`, a list of the app's features: what each does, how a user reaches it,
  where its code lives and which scenario covers it.
- Drivers for the kind of app you have: a browser driver for web and Electron apps, a
  tmux driver for terminal apps, screenshots for desktop apps.

The steps:

1. **Look for what exists.** If the project already has a way to verify, it extends that.
   Two ways to verify is one too many.
2. **Learn how the app runs.** It reads the CI configuration first, because what CI runs
   is the truth. Then it builds and runs the app once by hand and notes every surprise.
3. **Choose how to drive the app** and what counts as evidence. The script only touches
   processes it started itself, never your own running dev server.
4. **Copy the template and write the configuration.** One fast `smoke` scenario that runs
   after every change, plus a few scenarios for the most important features.
5. **Write the feature map** from the code: routes, menus, commands.
6. **Prove it works, and that it can fail.** It breaks something on purpose and confirms
   the run fails. A check that has never failed may be checking nothing.
7. **Wire it in.** It adds a "definition of done" to the project's agent instructions, so
   agents run the scenarios before they report a change as finished.

Each result is verified, not verified or inconclusive. A check that could not run is
inconclusive, and that is not a pass.

## How it connects

- [garden](garden.md) runs the generated skill's map checks during a health pass, and
  can trigger its audit of stale entries.
- [orchestrate](orchestrate.md) does not call this skill, but it requires that someone
  drives the real application. A `verify-<app>` skill is a ready way to do that.

You run it once per application. After that, agents use the `verify-<app>` skill it
created.

## How to ask for it

"Set up verification so agents can test this app themselves."
