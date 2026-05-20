# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/), wersjonowanie [SemVer](https://semver.org/).

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

[0.1.0]: https://github.com/Brbn-jpg/claude-conductor/releases/tag/v0.1.0
