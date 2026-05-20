#!/usr/bin/env bash
# worker-agent.sh — pojedynczy worker w gridzie AI.
#
# Użycie: ./worker-agent.sh <WORKER_ID>
#   np.   ./worker-agent.sh worker-1
#
# Pętla: pobierz najstarsze zadanie z .tasks/todo/, zarezerwuj atomowym
# mkdir-lockiem, uruchom AI, opcjonalnie odpal testy, zacommituj, oznacz done.
# Brak zadań -> exit. Crash / Ctrl-C -> rollback (zadanie wraca do todo/, lock zwolniony).

set -uo pipefail

# --- KONFIGURACJA -----------------------------------------------------------

# Komenda testująca. Pusta = pomiń weryfikację (zadania commitujemy od razu).
# Przykłady: "npm test", "pytest -q", "go test ./...", "make check".
TEST_CMD="${TEST_CMD:-}"

# Składnia wywołania Gemini CLI. ŁATWO PODMIENIĆ POD WŁASNE NARZĘDZIE.
# Funkcja dostaje prompt na stdin, ma wypisać odpowiedź na stdout.
#
# Sprawdzone z gemini-cli 0.42.0:
#   - `-p/--prompt "<TEXT>"` włącza tryb headless (non-interactive)
#   - `--yolo` auto-akceptuje WSZYSTKIE akcje modela (konieczne, żeby worker
#     mógł sam modyfikować pliki bez czekania na potwierdzenie)
#   - `--skip-trust` pomija pytanie o zaufanie do workspace'u
# Jeśli używasz innego CLI (claude, ollama, llm itp.) — podmień ciało funkcji.
run_ai() {
    if ! command -v gemini >/dev/null 2>&1; then
        echo "[run_ai] BŁĄD: brak komendy 'gemini' w PATH." >&2
        return 127
    fi
    local prompt
    prompt="$(cat)"
    # >>> ZMIEŃ TUTAJ, jeśli używasz innej składni / innego CLI. <<<
    gemini --yolo --skip-trust --prompt "$prompt" 2>&1
}

# Co ile sekund odpytywać kolejkę gdy wszystkie widoczne taski są zalockowane.
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# --- ŚCIEŻKI ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

TODO_DIR="$REPO_ROOT/.tasks/todo"
IN_PROGRESS_DIR="$REPO_ROOT/.tasks/in_progress"
DONE_DIR="$REPO_ROOT/.tasks/done"
LOCKS_DIR="$REPO_ROOT/.agent-locks"
LOGS_DIR="$REPO_ROOT/.agent-logs"

WORKER_ID="${1:-worker-$$}"
WORKER_LOG="$LOGS_DIR/${WORKER_ID}.log"

mkdir -p "$TODO_DIR" "$IN_PROGRESS_DIR" "$DONE_DIR" "$LOCKS_DIR" "$LOGS_DIR"

# --- STAN GLOBALNY (do rollbacku) ------------------------------------------

CURRENT_LOCK=""        # ścieżka do katalogu locka, jeśli posiadany
CURRENT_TASK_NAME=""   # np. task-001.md
CURRENT_IN_PROGRESS="" # ścieżka pliku w in_progress/

# --- LOGOWANIE --------------------------------------------------------------

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%s] %s\n' "$ts" "$WORKER_ID" "$*" | tee -a "$WORKER_LOG"
}

# --- CLEANUP / TRAP --------------------------------------------------------

rollback_current() {
    # Wraca zadanie z in_progress/ z powrotem do todo/ i zwalnia lock.
    # Bezpieczne do wywołania nawet jeśli nic nie trzymamy.
    if [[ -n "$CURRENT_IN_PROGRESS" && -f "$CURRENT_IN_PROGRESS" ]]; then
        local back="$TODO_DIR/$CURRENT_TASK_NAME"
        if mv "$CURRENT_IN_PROGRESS" "$back" 2>/dev/null; then
            log "ROLLBACK: zwrócono $CURRENT_TASK_NAME do todo/"
        else
            log "ROLLBACK: NIE udało się zwrócić $CURRENT_IN_PROGRESS"
        fi
    fi
    if [[ -n "$CURRENT_LOCK" && -d "$CURRENT_LOCK" ]]; then
        if rmdir "$CURRENT_LOCK" 2>/dev/null; then
            log "ROLLBACK: zwolniono lock $(basename "$CURRENT_LOCK")"
        fi
    fi
    CURRENT_LOCK=""
    CURRENT_TASK_NAME=""
    CURRENT_IN_PROGRESS=""
}

on_exit() {
    local code=$?
    if [[ -n "$CURRENT_TASK_NAME" ]]; then
        log "Przerwanie podczas pracy nad $CURRENT_TASK_NAME (exit=$code) — rollback."
        rollback_current
    fi
    log "Worker zakończył działanie (exit=$code)."
}
trap on_exit EXIT
trap 'log "Otrzymano SIGINT/SIGTERM, zamykam..."; exit 130' INT TERM

# --- LOCKING (atomowy mkdir) -----------------------------------------------

acquire_lock() {
    # $1 = TASK_NAME (np. task-001.md). Sukces => echo ścieżki do locka.
    local task_name="$1"
    local lock_path="$LOCKS_DIR/${task_name}.lock"
    # mkdir w POSIX-ie jest atomowy: tylko jeden proces dostanie 0,
    # reszta dostanie EEXIST. To nasz race-free guard.
    if mkdir "$lock_path" 2>/dev/null; then
        printf '%s' "$lock_path"
        return 0
    fi
    return 1
}

# Globalny mutex dla operacji git. Bez tego dwa workery wykonujące równolegle
# 'git add -A' wciągnęłyby sobie nawzajem zmiany pod jeden commit (working tree
# jest wspólny). Dla pełnej izolacji warto rozważyć 'git worktree' na worker.
GIT_MUTEX="$LOCKS_DIR/_git.mutex"
GIT_MUTEX_TIMEOUT="${GIT_MUTEX_TIMEOUT:-120}"

git_mutex_acquire() {
    local waited=0
    while ! mkdir "$GIT_MUTEX" 2>/dev/null; do
        if (( waited >= GIT_MUTEX_TIMEOUT )); then
            log "git_mutex: timeout (${GIT_MUTEX_TIMEOUT}s) — coś jest zaklinowane."
            return 1
        fi
        sleep 1
        ((waited++))
    done
    return 0
}

git_mutex_release() {
    rmdir "$GIT_MUTEX" 2>/dev/null || true
}

# --- WYBÓR ZADANIA ---------------------------------------------------------

# Iteruje po plikach todo/*.md w kolejności leksykograficznej, próbuje
# zaclaimować pierwszy wolny. Sukces => ustawia CURRENT_* i zwraca 0.
# Brak plików => return 2. Wszystkie zajęte => return 1.
claim_next_task() {
    shopt -s nullglob
    local candidates=( "$TODO_DIR"/*.md )
    shopt -u nullglob

    if (( ${#candidates[@]} == 0 )); then
        return 2
    fi

    local file task_name lock
    for file in "${candidates[@]}"; do
        task_name="$(basename "$file")"
        # Ignoruj plik .keep i ukryte
        [[ "$task_name" == .* ]] && continue

        if lock="$(acquire_lock "$task_name")"; then
            # Mamy lock — teraz spróbuj przenieść plik do in_progress.
            local dst="$IN_PROGRESS_DIR/$task_name"
            if mv "$file" "$dst" 2>/dev/null; then
                CURRENT_LOCK="$lock"
                CURRENT_TASK_NAME="$task_name"
                CURRENT_IN_PROGRESS="$dst"
                return 0
            else
                # Plik zniknął (np. ręczna interwencja) — zwolnij lock i jedź dalej.
                rmdir "$lock" 2>/dev/null || true
                log "Plik $task_name zniknął po lockowaniu, próbuję następne."
                continue
            fi
        fi
        # Lock zajęty przez inny worker — pomiń.
    done
    return 1
}

# --- WYKONANIE ZADANIA -----------------------------------------------------

execute_task() {
    local task_path="$CURRENT_IN_PROGRESS"
    local task_name="$CURRENT_TASK_NAME"
    local task_log="$LOGS_DIR/${WORKER_ID}_${task_name}.log"

    log "START: $task_name (log: $(basename "$task_log"))"

    # Zbuduj prompt. Zawartość zadania trafia w całości, plus krótka instrukcja systemowa.
    local prompt
    prompt="$(cat <<EOF
Jesteś ekspertem programowania pracującym w lokalnym repozytorium.
Wykonaj poniższe zadanie modyfikując odpowiednie pliki projektu.
Stosuj się ŚCIŚLE do sekcji "Ograniczenia (Definition of Done)".
Nie pytaj — wprowadź zmiany. Po skończeniu zwróć krótkie potwierdzenie.

=== TREŚĆ ZADANIA ($task_name) ===
$(cat "$task_path")
=== KONIEC ZADANIA ===
EOF
)"

    {
        echo "===== PROMPT ====="
        echo "$prompt"
        echo "===== OUTPUT ====="
    } >"$task_log"

    # Uruchom AI. Output trafia do logu zadania.
    if printf '%s' "$prompt" | run_ai >>"$task_log" 2>&1; then
        log "AI: $task_name — zakończone sukcesem (kod 0)."
    else
        local rc=$?
        log "AI: $task_name — BŁĄD (kod $rc). Rollback."
        echo "===== AI EXIT CODE: $rc =====" >>"$task_log"
        return 1
    fi

    # --- Sekcja krytyczna: tests + git ----------------------------------
    # Wszystko poniżej dotyka wspólnego working tree i indeksu git, więc
    # ujmujemy to w globalnym mutexie żeby nie zlewać zmian między workery.
    if ! git_mutex_acquire; then
        log "MUTEX: nie udało się zdobyć git mutexa — rollback."
        return 4
    fi

    # Opcjonalna weryfikacja testami.
    if [[ -n "$TEST_CMD" ]]; then
        log "TEST: uruchamiam '$TEST_CMD'"
        echo "===== TEST OUTPUT ($TEST_CMD) =====" >>"$task_log"
        if ! ( cd "$REPO_ROOT" && eval "$TEST_CMD" ) >>"$task_log" 2>&1; then
            log "TEST: $task_name — FAIL. Cofam zmiany robocze."
            ( cd "$REPO_ROOT" && git checkout -- . ) >>"$task_log" 2>&1 || true
            ( cd "$REPO_ROOT" && git clean -fd ) >>"$task_log" 2>&1 || true
            git_mutex_release
            return 2
        fi
        log "TEST: PASS."
    else
        log "TEST: pominięty (TEST_CMD pusty)."
    fi

    # Commit zmian.
    (
        cd "$REPO_ROOT" || exit 3
        git add -A
        if git diff --cached --quiet; then
            echo "===== GIT: brak zmian do zacommitowania =====" >>"$task_log"
            exit 10
        fi
        git commit -m "[AI-Grid] Zrobiono $task_name" >>"$task_log" 2>&1
    )
    local commit_rc=$?
    git_mutex_release

    case "$commit_rc" in
        0)  log "GIT: commit OK dla $task_name." ;;
        10) log "GIT: AI nie wprowadziło zmian — zadanie domknięte bez commita." ;;
        *)  log "GIT: BŁĄD commita ($commit_rc) dla $task_name."; return 3 ;;
    esac

    return 0
}

# --- PĘTLA GŁÓWNA ----------------------------------------------------------

log "Start workera. REPO=$REPO_ROOT  TEST_CMD='${TEST_CMD:-<none>}'"

while true; do
    if claim_next_task; then
        if execute_task; then
            # Sukces — przenieś do done/, zwolnij lock.
            mv "$CURRENT_IN_PROGRESS" "$DONE_DIR/$CURRENT_TASK_NAME"
            rmdir "$CURRENT_LOCK" 2>/dev/null || true
            log "DONE: $CURRENT_TASK_NAME"
            CURRENT_LOCK=""
            CURRENT_TASK_NAME=""
            CURRENT_IN_PROGRESS=""
        else
            # Porażka — rollback (przywróć do todo/, zwolnij lock).
            log "FAIL: rollback dla $CURRENT_TASK_NAME"
            rollback_current
        fi
    else
        case "$?" in
            2)  log "Kolejka pusta — kończę."; break ;;
            1)  # wszystkie widoczne taski zalockowane przez inne workery
                sleep "$POLL_INTERVAL" ;;
        esac
    fi
done

exit 0
