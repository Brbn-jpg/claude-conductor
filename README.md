# claude-conductor

Lokalny **Multi-Agent Coding Grid** zbudowany wyłącznie z Basha, systemu plików, `tmux` oraz Gemini CLI. Opisujesz zadania jako pliki Markdown, równolegli workerzy AI wykonują je w **izolowanych worktreach git**, każdy commit ląduje na osobnej gałęzi `ai-grid/<task>`, a Ty (lub Claude w roli Menedżera — patrz [`CLAUDE.md`](CLAUDE.md)) mergujesz to, co się sprawdza.

## Architektura

```
                    +--------------------+
   Manager  ---->   |  .tasks/todo/      |   (kolejka)
 (Ty / Claude)      +---------+----------+
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
  |   tmux    |         |   tmux    |         |   tmux    |
  |   pane    |         |   pane    |         |   pane    |
  +-----+-----+         +-----+-----+         +-----+-----+
        |                     |                     |
   mkdir-lock            mkdir-lock            mkdir-lock
        |                     |                     |
        v                     v                     v
  .worktrees/            .worktrees/           .worktrees/
   worker-1/              worker-2/             worker-N/
   gemini --yolo          gemini --yolo         gemini --yolo
        |                     |                     |
   git commit --->        git commit --->       git commit --->
   ai-grid/task-A         ai-grid/task-B        ai-grid/task-C
        \_____________________|_____________________/
                              |
                              v
                    Manager merguje do main
```

Każdy worker działa w **swoim** worktree i commituje na **swoją** gałąź — wspólne working tree (i związany z nim race przy `git add -A`) jest fundamentalnie wyeliminowane.

## Wymagania

- **bash** (4+ działa, 5+ rekomendowane)
- **git**
- **tmux** (`brew install tmux` / `apt install tmux`)
- **gemini CLI** zalogowany (testowane na 0.42.0). Wystarczy `gemini` w PATH + auth wykonany raz interaktywnie.

## Quickstart

```bash
# 1. Dorzuć zadanie do kolejki:
cp .tasks/_template.md .tasks/todo/task-001-moj-task.md
$EDITOR .tasks/todo/task-001-moj-task.md

# 2. Odpal grid (domyślnie 2 workery):
./launch-grid.sh --workers 2
# Sesja tmux 'ai-grid' otwiera się z N panelami.
# Detach: Ctrl-b d   |   Ponowny attach: tmux attach -t ai-grid

# 3. Po pracy workerów: przegląd gałęzi ai-grid/*
git branch | grep ai-grid
git log -p ai-grid/task-001-moj-task

# 4. Merge tego, co OK:
git merge --no-ff ai-grid/task-001-moj-task
```

Tryb headless (np. z CI lub z poziomu innego agenta):

```bash
./launch-grid.sh --workers 3 --no-attach
# Sesja działa w tle; obserwacja: tmux attach -t ai-grid
```

## Struktura projektu

| Ścieżka | Rola |
|---|---|
| `launch-grid.sh` | Orkiestrator: czyści stare locki, tworzy sesję tmux, dzieli ją na panele, uruchamia workerów |
| `worker-agent.sh` | Pętla workera: claim → AI → testy → commit → done |
| `.tasks/_template.md` | Szablon zadania (Cel / Kontekst / Pliki / DoD) |
| `.tasks/todo/` | Kolejka oczekujących zadań |
| `.tasks/in_progress/` | Aktywnie przetwarzane (po zaclaimowaniu) |
| `.tasks/done/` | Ukończone (audyt) |
| `.agent-locks/` | Atomowe locki `mkdir` per task + `_git.mutex` (legacy, niewykorzystywany przy worktree) |
| `.agent-logs/` | Logi: `<worker>.log` (worker-level) + `<worker>_<task>.log` (per-task, z promptem i AI output) |
| `.worktrees/<worker-id>/` | Izolowany working tree workera (runtime, gitignored) |
| `CLAUDE.md` | Instrukcje dla Claude jako Menedżera |

## Konfiguracja

Wszystkie pokrętła znajdziesz na górze `worker-agent.sh`:

| Zmienna | Domyślnie | Opis |
|---|---|---|
| `TEST_CMD` | `""` | Komenda testująca po AI. Pusta = pomiń. Przykłady: `"npm test"`, `"pytest -q"`, `"go test ./..."`. |
| `POLL_INTERVAL` | `5` | Sekund między próbami pobrania zadania gdy wszystkie widoczne są zalockowane. |
| `BASE_BRANCH` | bieżąca gałąź | Gałąź, z której każdy task tworzy świeży branch `ai-grid/<task>`. |
| `run_ai()` | `gemini --yolo --skip-trust --prompt …` | Funkcja-adapter. **Podmień ciało** aby użyć innego CLI (claude, ollama, llm itp.). |

`launch-grid.sh`:
- `--workers N` / `-w N` — liczba paneli (domyślnie 2)
- `--no-attach` — twórz sesję i wyjdź (nie uruchamiaj `tmux attach`)

## Bezpieczeństwo równoległości

| Mechanizm | Co rozwiązuje |
|---|---|
| **Atomowy `mkdir` lock** | Dwa workery widzące ten sam plik w `todo/` — tylko jeden wygra `mkdir .agent-locks/<task>.lock` (POSIX gwarantuje atomowość). |
| **Worktree per worker** | Brak wspólnego working tree → brak race przy `gemini` zapisującym pliki i `git add -A`. Każdy worker = własny `.worktrees/<worker-id>`. |
| **Branch per task** | Każdy commit ląduje na `ai-grid/<task-name>`, dzięki czemu `git add -A` w jednym worktree nie wciąga zmian innego workera. |
| **Trap rollback** | SIGINT/SIGTERM/crash → task wraca z `in_progress/` do `todo/`, lock zwolniony, worker wychodzi czysto. |
| **Stale lock cleanup** | `launch-grid.sh` przy starcie usuwa locki starsze niż 60 min (po crashu workera, który nie zdążył odpalić trapa). |

## Cykl pracy z Claude jako Menedżerem

Patrz `CLAUDE.md`. W skrócie:

1. Opisujesz duży problem → Claude dzieli go na zadania w `.tasks/todo/` używając szablonu.
2. Mówisz "uruchom grid" → Claude odpala `./launch-grid.sh --workers N` (lub prosi Cię o uruchomienie).
3. Workerzy pracują równolegle, commitują na `ai-grid/<task>`.
4. Po zakończeniu → Claude weryfikuje logi i commity, pyta Cię o zgodę na merge i push.

## Codzienne komendy

```bash
# Atach / detach / kill sesji
tmux attach -t ai-grid
Ctrl-b d                                        # detach z poziomu tmux
tmux kill-session -t ai-grid

# Sprzątanie po sesji
git worktree remove .worktrees/worker-1
git worktree remove .worktrees/worker-2
git branch -D ai-grid/task-001-moj-task         # po mergu

# Status kolejki
ls .tasks/{todo,in_progress,done}/

# Logi konkretnego workera / taska
tail -f .agent-logs/worker-1.log
cat .agent-logs/worker-1_task-001-moj-task.md.log
```

## Znane ograniczenia

- **Workery wyłączają się** po opróżnieniu `todo/`. Jeśli chcesz „demona", który trzyma się do `Ctrl-c`, zamień `break` w pętli głównej `worker-agent.sh` na `sleep "$POLL_INTERVAL"; continue`.
- **Brak licznika prób** przy crashu AI — task wraca do kolejki, ale teoretycznie może crashować w nieskończoność. W praktyce gemini jest stabilny, ale warto dodać limit.
- **Stale-lock cleanup** ma sztywno wpisane 60 min. Jeśli zadanie potrafi trwać dłużej, podnieś `STALE_LOCK_MINUTES` w `launch-grid.sh`.
- **AI w `--yolo`** = auto-akceptacja wszystkich akcji modela. Używaj na lokalnym branchu / w worktree (czego framework pilnuje), nie odpalaj na produkcyjnym repo bez testów.
