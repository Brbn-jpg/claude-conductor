# <Short feature description — THIS becomes the commit message>

> Save this file as `.tasks/todo/task-<NNN>-<short-slug>.md`.
> The first H1 above is used as the worker's **commit subject**
> (e.g. "Add electrician job page", "Refactor auth middleware"). The file
> name lands in the `AI-Grid: <task-name>` trailer in the commit body
> (for audit). Write the H1 like a normal commit message — short,
> imperative mood.

## Goal
<!-- 1–2 sentences: what exactly should be achieved when this task is done. -->

## Context
<!-- Why are we doing this? Links to issues / docs / earlier decisions. -->
<!-- Current state vs. expected state. -->

## Files to modify
<!-- Concrete paths (one per line). If a file needs to be created, append "(new)". -->
- `path/to/file.ext`
- `path/to/other.ext` (new)

## Constraints (Definition of Done)
<!-- Hard rules: what NOT to touch, which APIs/conventions to follow, -->
<!-- what the completion criterion looks like (e.g. a test that must pass). -->
- Do not modify files outside the list above.
- Preserve existing code style and naming conventions.
- After changes, the worker's `TEST_CMD` must pass without errors.
- Do not add external dependencies without explicit approval.
