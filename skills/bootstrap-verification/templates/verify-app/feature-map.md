# Feature map: __APP_NAME__

What the app does, how a user gets to each feature, and where the code lives. Agents use this
to understand vague requests and bug reports, and to pick which scenarios to run.

Format: one `##` section per feature, with `- key: value` lines. `verify.py check-map`
validates `id`, `code` (paths or globs, comma-separated) and `verify` (scenario names).
Other keys are free text for humans and agents.

Keys:
- id: short unique slug (used by scenarios' "features" lists)
- what: one or two sentences on what it does for the user
- reach: how a user gets there: URL, menu path, keyboard shortcut, command, CLI subcommand
- ui: how to recognise it: visible labels, accessible names, test ids, window titles, prompts
- code: where it's implemented
- verify: scenarios that exercise it
- notes: edge cases, known quirks, related features
- reviewed: date the entry was last checked against the app. `verify.py stale-map` lists
  features whose code changed after their entry was last edited; updating this date is how
  an audit records "still accurate"

<!-- Example (replace with real features) -->

## Search
- id: search
- what: Finds items by name or tag as you type; shows at most 50 results.
- reach: Ctrl+K anywhere, or the magnifier icon in the top bar; URL /search?q=...
- ui: input with placeholder "Search…"; results list [data-testid=search-results]
- code: src/features/search/, src/api/search.ts
- verify: smoke, search-basic
- notes: Results are cached for 30 s. Empty query shows recent items.
- reviewed: 2026-01-15
