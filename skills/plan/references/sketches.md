# Code sketches and slicing

## Code sketches

Required in every plan slice and every coding brief. Their purpose is that
the coder implements the plan's design instead of inventing one, so the
result behaves as planned and review is a comparison rather than a
discovery. A sketch contains, in the project's language and with its real
identifiers:

- the data shapes and types, first
- the signatures of the functions and methods to add or change
- what else the change must reach: the callers, tests, fixtures, config and
  exports that use what it changes
- the control flow of anything not obvious, including parsing and error
  handling at boundaries
- a pointer to the existing code to imitate (`path:line`)
- the test cases to write before the implementation

Mark types, signatures and observable behavior **binding**, function bodies
**illustrative**, and symbols the plan introduces **new**. Stop short of a
full implementation: that would be the planner coding, and it leaves the
coder nothing to verify against the real code.

Sketches follow the coding standards: the failing test comes first; the data
shape is settled before the logic; outside data is parsed once at the
boundary; a requirement the current design cannot hold gets a redesign in
slices, not a patch onto the old shape.

## Slicing

Each slice is one verifiable unit: a coder can finish it and run a check,
and a reviewer can review it alone. Default for a non-trivial feature, each
its own coding and review cycle:

1. Core type and API with unit tests: no migration, no call-site churn
   beyond what the tests need.
2. Wiring: pass the new types through call sites, handlers, stores.
3. Migration, collapse or merge.

Do not bundle these into one first slice unless the change is trivial.
Foundations come first: data shapes, shared types, the verification harness.
Say which slices depend on which. Slices that touch the same files run in
order.

**Stateful work** (paths, migration, merge, shared state, crash recovery):
list the invariants, and give each one test in the same slice.

## Verification in the real application

For each behavior the work adds or changes, say how an agent will drive the
application to see it working: which driver or harness, which user actions,
and what the user would observe on success. Look for what exists first: a
project verification skill (often `verify-<app>`), an end-to-end suite, a
driver or harness in the repository, a documented way to launch the app.

For a fix, the first scenario is the reproduction: the user actions that show
the failure today, and what the user sees. It runs twice, before any code
changes and after the fix, and the second run shows the failure gone. A test
that fails without the fix does not replace it.

Where nothing can drive the behavior, plan the means as its own early slice,
with sketches like any other: the harness or driver, how the app is launched
in a controllable state, and one scenario that proves the harness works.
Prefer a reusable harness in the repository over a one-off script.

Some things an agent cannot drive: a production-only service, physical
hardware, an account the session must not use. Name the gap and the reason;
the user checks that part.

The real application does not mean the user's real data. Launch it with a
temporary config, profile and data folder, and say so in the plan.
