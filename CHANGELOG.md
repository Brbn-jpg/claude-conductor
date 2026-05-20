# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/), wersjonowanie [SemVer](https://semver.org/).

## [0.3.0] — 2026-05-20

Linear-history integration. Przy 14 workerach domyślne `git merge --no-ff` produkowało spaghetti (28 commitów + 14 równoległych railsów na 14 tasków). Nowy `integrate.sh` używa cherry-pick: każdy task → jeden commit na main, bez merge-commitów, z automatycznym cleanupem worktree i gałęzi.

### Added

- **`integrate.sh`** — cherry-pickuje gałęzie `ai-grid/*` na bieżącą gałąź. Tryby: pojedyncza gałąź, `--all`, `--dry-run`, `--keep-branch`. Sanity-check working tree przed startem; STOP-uje z czytelnym komunikatem przy konflikcie (kod 4) zostawiając pozostałe gałęzie nietknięte. Po sukcesie usuwa worker worktree + gałąź `ai-grid/<task>`.

### Changed

- **`CLAUDE.md`** — sekcja "Integracja" w "Autonomicznym trybie": manager używa `./integrate.sh --all` zamiast `git merge --no-ff`. Konflikt → przerwij autonomię, zapytaj użytkownika.
- **`README.md`** — quickstart pokazuje `./integrate.sh --all`, sekcja "Sprzątanie" zaznacza, że integrate.sh robi to automatycznie.

### Why

`git merge --no-ff` zachowuje "to było na osobnej gałęzi" — ale w naszym workflow każda gałąź ma dokładnie 1 commit (worker commituje raz), więc ta informacja jest bezwartościowa. Cherry-pick przepisuje commit na main z nowym SHA, ale identycznym commit message ("[AI-Grid] Zrobiono task-XXX"). Wynik: czytelny `git log --oneline`, `git bisect` działa normalnie, review 1:1 z taskiem.

## [0.2.0] — 2026-05-20

Optymalizacja zużycia tokenów dla managera (Claude Code / inny LLM-orchestrator). Worker pisze zwięzłe podsumowanie per task, nowy `status.sh` agreguje stan gridu w jednym wywołaniu, dochodzi szablon research-task pozwalający delegować eksplorację codebase'u do gemini. Manager może operować end-to-end autonomicznie zamiast dopytywać o każdy krok.

### Added

- **Task summary per worker** — po commicie worker zapisuje `.agent-logs/<worker>_<task>.summary.md` z `WORKER`, `RESULT` (OK/AI-FAIL/TEST-FAIL/COMMIT-FAIL/NO-CHANGES), `BRANCH`, `COMMIT`, `FILES_CHANGED`, `DIFF`, `TEST_CMD`, `FINISHED` + listą plików. Manager czyta 16 linii zamiast pełnego AI logu (~3–5× oszczędność w fazie review).
- **`status.sh`** — jednolinijkowy raport stanu gridu: kolejka (todo/in_progress/done), gałęzie `ai-grid/*` z diff stats, large-diff flagi (> `LARGE_DIFF_LINES`, domyślnie 100), locki ze stale-detection (>60 min), sesje tmux, recent summaries z `RESULT`. Bash 3.2-portable.
- **`.tasks/_template-research.md`** — szablon dla research-task: gemini eksploruje wskazany zakres, zapisuje raport do `.tasks/research/<slug>.md` (TL;DR + Findings + Recommendations, max 300 słów). Manager konsumuje streszczenie zamiast czytać surowy kod (~5–10× oszczędność w fazie discovery).
- **Sekcja "Autonomiczny tryb" w `CLAUDE.md`** — instrukcja dla LLM-managera: planuj → odpalaj `./launch-grid.sh --no-attach` sam → polluj `.tasks/done/` → review przez `./status.sh` + summary files (nie pełne logi) → auto-merge dla diffów < `LARGE_DIFF_LINES` → ZAWSZE pytaj przed `git push`.

### Changed

- `worker-agent.sh` — dodana funkcja `write_task_summary` wywoływana na każdym terminale `execute_task` (success / AI-fail / test-fail / commit-fail / no-changes).

## [0.1.0] — 2026-05-20

Pierwszy publiczny release. Lokalny **multi-agent coding grid** zbudowany wyłącznie z natywnych narzędzi: Bash, system plików, `tmux`, gemini CLI. Odpalasz N workerów AI równolegle — każdy w izolowanym git worktree, każdy commituje na własną gałąź `ai-grid/<task>`.

### Highlights

- **Atomowy locking przez `mkdir`** — POSIX-atomowy guard. Dwa workery widzące ten sam plik w kolejce nigdy go nie zaclaimują równocześnie. Bez `flock`, bez SQL'a, bez Redisa.
- **Worktree per worker** — każdy worker pracuje w `.worktrees/<worker-id>/`. Brak wspólnego working tree → brak race przy `git add -A` ani konfliktu plików między równoległymi gemini.
- **Branch per task** — `git checkout -B ai-grid/<task-name> $BASE_SHA` przed każdym zadaniem. Mergujesz tylko to, co OK, odrzucasz resztę.
- **Crash-safe** — `trap EXIT/INT/TERM` zwraca zadanie z `in_progress/` do `todo/` i zwalnia lock przy SIGINT/SIGTERM/exception.
- **Stale-lock cleanup** — `launch-grid.sh` przy starcie usuwa locki starsze niż 60 minut (na wypadek workera, który padł bez czasu na trap).
- **Pluggable AI backend** — funkcja `run_ai()` na górze `worker-agent.sh` do podmiany pod claude-code, ollama, llm lub cokolwiek innego.

### Components

| Plik | Rola |
|---|---|
| `launch-grid.sh` | Orkiestrator tmux: `--workers N`, `--no-attach`, cleanup starych locków |
| `worker-agent.sh` | Pojedynczy worker (claim → AI → testy → commit → done), w worktree |
| `.tasks/_template.md` | Szablon zadania (Cel / Kontekst / Pliki / Definition of Done) |
| `CLAUDE.md` | Instrukcje dla Claude Code w roli managera (opcjonalne) |
| `README.md`, `LICENSE` | Dokumentacja + MIT License |

### Requirements

- bash 4+ (5+ rekomendowane)
- git, tmux
- gemini CLI ([Google Gemini CLI](https://github.com/google-gemini/gemini-cli)) — testowane na 0.42.0, jednorazowy `gemini auth login`

### Quick start

```bash
git clone https://github.com/Brbn-jpg/claude-conductor.git && cd claude-conductor
cp .tasks/_template.md .tasks/todo/task-001-cos.md
$EDITOR .tasks/todo/task-001-cos.md
./launch-grid.sh --workers 2
```

### Known limitations

- **Workery wyłączają się po opróżnieniu `todo/`** — nie pracują w trybie demon. Żeby reagowały na nowe taski w tle, zamień `break` na `sleep "$POLL_INTERVAL"; continue` w pętli głównej `worker-agent.sh`.
- **Brak licznika prób** — task po crashu AI wraca do kolejki bez limitu.
- **Stale-lock threshold sztywny (60 min)** — podnieś `STALE_LOCK_MINUTES` w `launch-grid.sh` dla długich zadań.
- **`gemini --yolo` = pełne zaufanie do AI**. Framework izoluje workery przez worktree, ale jakość promptu (Definition of Done w szablonie) determinuje jakość output'u.
- **Skrypty zakładają, że żyją w roocie target repo** (`REPO_ROOT="$SCRIPT_DIR"`). Reuse w innym repo = skopiuj pliki tam (patrz README).

### Acknowledgments

Inspirowane wątkiem na Reddicie o lekkich multi-agent setupach. Zbudowane na zasadzie "ile da się wyciągnąć z natywnych narzędzi POSIXa zanim sięgniemy po orkiestratory".

---

[0.3.0]: https://github.com/Brbn-jpg/claude-conductor/releases/tag/v0.3.0
[0.2.0]: https://github.com/Brbn-jpg/claude-conductor/releases/tag/v0.2.0
[0.1.0]: https://github.com/Brbn-jpg/claude-conductor/releases/tag/v0.1.0
