# claude-conductor

> **Odpal N agentów AI równolegle. Bash + tmux + gemini CLI. Zero frameworków.**

Wrzucasz zadania do `.tasks/todo/` jako pliki Markdown. `./launch-grid.sh --workers N` odpala N pracujących workerów w sesji `tmux` — każdy w **swoim worktree git**, każdy commit na **swojej gałęzi** `ai-grid/<task>`. Po zakończeniu Ty (jako manager) mergujesz to, co OK.

Bez Docker'a, bez Pythonów, bez orkiestratorów. Plik lock-owy to katalog utworzony przez `mkdir`. Kolejka to katalog z plikami `.md`. Tyle.

## Po co to?

Masz pakiet małych, **niezależnych** zadań — "dopisz 5 testów do tych endpointów", "wygeneruj fixtury do 12 modeli", "przygotuj 8 README do submodułów"? Zamiast czekać aż jedna instancja AI to przemiele sekwencyjnie, odpalasz N workerów. Bo gemini-cli (lub dowolne inne CLI po podmianie jednej funkcji) z `--yolo` może operować na repo bez nadzoru, ale tylko jeśli każdy ma **własną piaskownicę**. Stąd worktree per worker.

## Jak to wygląda

```
                    +--------------------+
        Manager  -> |  .tasks/todo/      |   (kolejka)
                    +---------+----------+
                              |
                              v
              .---------------+---------------.
              |  launch-grid.sh (tmux + N)    |
              '---------------+---------------'
                              |
        +---------------------+---------------------+
        v                     v                     v
  +-----------+         +-----------+         +-----------+
  |  worker-1 |         |  worker-2 |   ...   |  worker-N |
  |   (tmux)  |         |   (tmux)  |         |   (tmux)  |
  +-----+-----+         +-----+-----+         +-----+-----+
        |                     |                     |
   mkdir-lock            mkdir-lock            mkdir-lock
        |                     |                     |
        v                     v                     v
  .worktrees/            .worktrees/           .worktrees/
   worker-1/              worker-2/             worker-N/
   gemini --yolo          gemini --yolo         gemini --yolo
        |                     |                     |
   git commit -->         git commit -->        git commit -->
   ai-grid/task-A         ai-grid/task-B        ai-grid/task-C
        \_____________________|_____________________/
                              |
                              v
                       Manager merguje
                       to, co się sprawdza
```

## Wymagania

- `bash` (4+ wystarczy, 5+ rekomendowane)
- `git`
- `tmux` (`brew install tmux` / `apt install tmux`)
- [gemini CLI](https://github.com/google-gemini/gemini-cli) zalogowany — testowane na 0.42.0. Wystarczy `gemini` w PATH i jednorazowy `gemini auth login`.

Nie używasz gemini? Podmień ciało jednej funkcji `run_ai()` na górze `worker-agent.sh` i to wszystko — działa z dowolnym CLI, które przyjmuje prompt i pisze do plików (claude-code, ollama, llm itp.).

## Quickstart

```bash
git clone https://github.com/Brbn-jpg/claude-conductor.git
cd claude-conductor

# 1. Stwórz zadanie z szablonu
cp .tasks/_template.md .tasks/todo/task-001-moj.md
$EDITOR .tasks/todo/task-001-moj.md   # wypełnij Cel / Kontekst / Pliki / DoD

# 2. Odpal grid (domyślnie 2 workery)
./launch-grid.sh --workers 2
# Ctrl-b d — odłącz od sesji   |   tmux attach -t ai-grid — wróć

# 3. Po zakończeniu zobacz co zrobili
./status.sh                             # przegląd jednym wywołaniem
git log -p ai-grid/task-001-moj         # podgląd diffu konkretnej gałęzi

# 4. Zintegruj (cherry-pick, linear history, sprząta worktree+branch)
./integrate.sh --all                    # wszystkie ai-grid/* na bieżącą gałąź
# albo wybrany task:
./integrate.sh ai-grid/task-001-moj
```

Tryb headless (CI / inny skrypt):

```bash
./launch-grid.sh --workers 3 --no-attach
# sesja działa w tle; podgląd: tmux attach -t ai-grid
```

## Jak to działa

Trzy mechanizmy, które robią różnicę:

1. **Atomowy lock przez `mkdir`** — workery widzące ten sam plik w kolejce nie zaclaimują go równocześnie. `mkdir foo.lock` jest atomowy na POSIX: tylko jeden proces dostaje kod 0, reszta `EEXIST`. Bez `flock`, bez SQL'a, bez Redisa.

2. **Worktree per worker** — `git worktree add --detach .worktrees/<worker-id> $BASE_BRANCH`. Gemini w `--yolo` zapisuje pliki tam, nie w głównym repo. Brak wspólnego working tree = brak race przy `git add -A`.

3. **Branch per task** — przed każdym taskiem worker robi `git checkout -B ai-grid/<task-name> $BASE_SHA` w swoim worktree. Commit ląduje na izolowanej gałęzi. Po sesji mergujesz to, co OK, odrzucasz resztę.

**Crash-safe**: `trap EXIT` w workerze przywraca task z `in_progress/` do `todo/` i zwalnia lock przy SIGINT/SIGTERM/exception. `launch-grid.sh` przy starcie sprząta locki starsze niż 60 minut (na wypadek workera, który padł bez czasu na trap).

## Struktura projektu

| Ścieżka | Rola |
|---|---|
| `launch-grid.sh` | Orkiestrator: cleanup locków, sesja tmux, `N` paneli z workerami |
| `worker-agent.sh` | Pętla pojedynczego workera: claim → AI → testy → commit → done |
| `status.sh` | Agregowany raport stanu gridu w jednym wywołaniu (kolejka, gałęzie, locki, summaries) |
| `integrate.sh` | Cherry-pick `ai-grid/*` na bieżącą gałąź (1 task = 1 commit, bez merge-commitów) + cleanup worktree/branch |
| `.tasks/_template.md` | Szablon zadania kodowego (Cel / Kontekst / Pliki / DoD) |
| `.tasks/_template-research.md` | Szablon research-task (gemini bada codebase, pisze raport zamiast zmieniać kod) |
| `.tasks/todo/` | Kolejka oczekujących zadań |
| `.tasks/in_progress/` | Aktywnie przetwarzane |
| `.tasks/done/` | Ukończone (audyt) |
| `.agent-locks/` | Atomowe locki `mkdir` per task |
| `.agent-logs/` | Logi: `<worker>.log`, `<worker>_<task>.log` (pełny AI output), `<worker>_<task>.summary.md` (zwięzły raport per task — manager czyta to zamiast pełnego logu) |
| `.worktrees/<worker-id>/` | Izolowany working tree workera (runtime, gitignored) |
| `CLAUDE.md` | Instrukcje dla Claude Code (gdy używasz go jako managera) |

## Konfiguracja

Wszystkie pokrętła są w pierwszych ~30 liniach `worker-agent.sh`:

| Zmienna | Domyślnie | Opis |
|---|---|---|
| `TEST_CMD` | `""` | Komenda testu po AI. Pusta = pomiń. `"npm test"`, `"pytest -q"`, `"go test ./..."`. Failure → reset worktree, task wraca do `todo/`. |
| `POLL_INTERVAL` | `5` | Sekund między próbami pobrania zadania gdy widoczne są same zalockowane. |
| `BASE_BRANCH` | bieżąca gałąź | Branch, od którego każdy task tworzy swoje `ai-grid/<task>`. |
| `run_ai()` | `gemini --yolo --skip-trust --prompt …` | **Funkcja-adapter.** Podmień ciało aby użyć innego CLI. |

`launch-grid.sh`:
- `--workers N` / `-w N` — liczba paneli (domyślnie 2)
- `--no-attach` — twórz sesję i wyjdź bez `tmux attach` (przydatne w CI)

## Sesja tmux — ściąga

```bash
tmux attach -t ai-grid             # podłącz do działającej sesji
# wewnątrz tmux:
#   Ctrl-b d        — detach (sesja działa dalej)
#   Ctrl-b <arrow>  — przeskocz między panelami
#   Ctrl-b z        — zoom na pojedynczy panel
tmux list-panes -t ai-grid         # zobacz panele z zewnątrz
tmux capture-pane -t ai-grid:grid.0 -p   # zrzut zawartości panelu 0
tmux kill-session -t ai-grid       # zabij całą sesję
```

## Sprzątanie po sesji

Domyślnie `./integrate.sh` robi to za Ciebie po każdym sukcesie (worktree + branch). Ręcznie tylko gdy chcesz odrzucić wyniki bez integracji:

```bash
git worktree list                              # zobacz aktywne worktree
git worktree remove --force .worktrees/worker-1
git branch -D ai-grid/task-XXX

# Reset całej sesji (wszystkie worktree workerów + gałęzie ai-grid):
git worktree list | awk '/.worktrees\// {print $1}' | xargs -n1 git worktree remove --force
git branch | awk '/ai-grid\//{print $1}' | xargs -r git branch -D
```

## Znane ograniczenia

- **Workery wyłączają się po opróżnieniu `todo/`.** Jeśli chcesz „demon w tle" reagujący na nowe taski, zamień `break` w pętli głównej `worker-agent.sh` na `sleep "$POLL_INTERVAL"; continue`.
- **Brak licznika prób** — task po crashu AI wraca do kolejki bez limitu. W praktyce gemini jest stabilny, ale dla produkcji dodaj cap (`.tasks/in_progress` można rozbudować o licznik).
- **Stale-lock cleanup** ma sztywne 60 min. Długie zadania? Podnieś `STALE_LOCK_MINUTES` w `launch-grid.sh`.
- **`--yolo` = pełne zaufanie AI.** Framework izoluje workery przez worktree, ale prompt sam się nie pisze: jakość zadania (DoD) determinuje jakość output'u. Trzymaj się szablonu.
- **Domyślnie liniowa kolejka** — workery biorą pliki leksykograficznie z `todo/`. Jeśli potrzebujesz priorytetów, prefiksuj nazwy (`task-001-`, `task-002-`).

## Bonus: praca z Claude Code

W repozytorium jest [`CLAUDE.md`](CLAUDE.md) z instrukcjami dla [Claude Code](https://claude.com/claude-code) w trybie "Manager + Workers": Claude dzieli duży problem na atomowe taski w `.tasks/todo/`, Ty mówisz "uruchom grid", Claude prosi o weryfikację commitów `[AI-Grid]` i o zgodę na push. Nie używasz Claude Code? Wszystko działa identycznie ręcznie — Ty piszesz taski, Ty mergujesz.

## Licencja

[MIT](LICENSE) © 2026 Jakub Kuźnicki
