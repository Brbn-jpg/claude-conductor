# Research: <short topic description — becomes the commit subject>

> Template for **research tasks** — output is a concise report, not code changes.
> Save this file as `.tasks/todo/research-<NNN>-<slug>.md`.
> The worker will run gemini which **explores the codebase**, writes findings to
> `.tasks/research/<slug>.md` (create the directory if missing) and that's it —
> no other repo changes. The manager (you / Claude) reads a short report
> instead of reading raw code themselves.

## Goal
<!-- What do you want to learn? E.g. "how module X works", "all places that
     use function Y", "compare 3 approaches to Z in the codebase". -->

## Exploration scope
<!-- Which paths / files / patterns the worker should search. The more concrete, the better. -->
- `src/...`
- files matching pattern: ...
- skip: ...

## Questions to answer
<!-- List of questions. Each gets answered in the report. -->
1. ...
2. ...
3. ...

## Output format (DoD)
- **Output file:** `.tasks/research/<slug>.md` (create `.tasks/research/` if missing)
- **Limit:** max 300 words
- **Report structure:**
  - `## TL;DR` — 3 lines, key takeaways
  - `## Findings` — bullet points, each with a file reference (`path/to/file.ext:LINE`)
  - `## Recommendations` *(optional)* — proposed actions / follow-up tasks

## Constraints
- **DO NOT modify** any files outside `.tasks/research/`.
- **DO NOT generate** test files or code — this is a report only.
- Code quotes max 5 lines each; rest as description.
