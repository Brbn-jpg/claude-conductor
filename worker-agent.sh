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
WORKTREES_DIR="$REPO_ROOT/.worktrees"

# Bazowa gałąź, od której każde nowe zadanie tworzy świeży branch.
# Domyślnie bieżąca gałąź głównego repo w momencie startu workera.
BASE_BRANCH="${BASE_BRANCH:-$(cd "$REPO_ROOT" && git symbolic-ref --short HEAD 2>/dev/null || echo HEAD)}"

WORKER_ID="${1:-worker-$$}"
WORKER_LOG="$LOGS_DIR/${WORKER_ID}.log"
WORK_DIR="$WORKTREES_DIR/$WORKER_ID"

mkdir -p "$TODO_DIR" "$IN_PROGRESS_DIR" "$DONE_DIR" "$LOCKS_DIR" "$LOGS_DIR" "$WORKTREES_DIR"

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

# Każdy worker ma własny git worktree (.worktrees/<worker-id>). Dzięki temu
# równolegli workerzy NIE mają wspólnego working tree — gemini każdego z nich
# operuje izolowanie, a commity lecą na osobne gałęzie ai-grid/<task-name>.
# Bezpiecznie pomijamy globalny mutex git.

ensure_worktree() {
    # Jeśli worktree już istnieje, tylko sprawdź sanity.
    if [[ -e "$WORK_DIR/.git" ]]; then
        return 0
    fi
    log "WORKTREE: tworzę $WORK_DIR (base=$BASE_BRANCH)"
    if ! ( cd "$REPO_ROOT" && git worktree add --detach "$WORK_DIR" "$BASE_BRANCH" ) >>"$WORKER_LOG" 2>&1; then
        log "WORKTREE: BŁĄD przy 'git worktree add'."
        return 1
    fi
    return 0
}

get_base_sha() {
    ( cd "$REPO_ROOT" && git rev-parse "$BASE_BRANCH" 2>/dev/null )
}

# Wyciąga subject commita z pliku zadania.
# Preferuje pierwszy H1 (linia "# Foo"). Jeśli brak lub placeholder
# z szablonu — fallback do slugu z nazwy pliku.
extract_commit_subject() {
    local task_file="$1"
    local task_name="$2"

    local h1=""
    if [[ -r "$task_file" ]]; then
        h1=$(grep -m1 '^# ' "$task_file" 2>/dev/null | sed 's/^# *//' | sed 's/[[:space:]]*$//')
    fi

    # Odrzuć placeholdery z szablonów
    case "$h1" in
        ""|"Tytuł zadania"|"Research: <temat>")
            # Fallback: slug z nazwy pliku  (task-101-job-electrician.md -> job-electrician)
            local slug="${task_name%.md}"
            slug="${slug#task-}"
            slug="${slug#research-}"
            slug=$(echo "$slug" | sed 's/^[0-9][0-9]*-//')
            echo "$slug"
            ;;
        *)
            echo "$h1"
            ;;
    esac
}

# Zapisuje zwięzłe summary per task do .agent-logs/<worker>_<task>.summary.md.
# Manager (Claude Code) czyta TO zamiast pełnego logu — oszczędność tokenów.
write_task_summary() {
    local result="$1"   # OK | AI-FAIL | TEST-FAIL | COMMIT-FAIL | NO-CHANGES
    local task_name="$CURRENT_TASK_NAME"
    local task_branch="ai-grid/${task_name%.md}"
    local summary_file="$LOGS_DIR/${WORKER_ID}_${task_name}.summary.md"

    local commit_sha="-"
    local files_changed_count="-"
    local diff_stat="-"
    local files_list="(none)"

    if [[ "$result" == "OK" && -d "$WORK_DIR" ]]; then
        commit_sha="$(cd "$WORK_DIR" && git rev-parse --short HEAD 2>/dev/null || echo '-')"
        local diff_range="${BASE_BRANCH}..HEAD"
        files_changed_count="$(cd "$WORK_DIR" && git diff --name-only "$diff_range" 2>/dev/null | wc -l | tr -d ' ')"
        diff_stat="$(cd "$WORK_DIR" && git diff --shortstat "$diff_range" 2>/dev/null | sed 's/^ *//')"
        files_list="$(cd "$WORK_DIR" && git diff --name-status "$diff_range" 2>/dev/null || echo '(none)')"
    fi

    {
        echo "# Summary: $task_name"
        echo
        echo "- **WORKER:** $WORKER_ID"
        echo "- **RESULT:** $result"
        echo "- **BRANCH:** $task_branch"
        echo "- **COMMIT:** $commit_sha"
        echo "- **FILES_CHANGED:** $files_changed_count"
        echo "- **DIFF:** ${diff_stat:--}"
        echo "- **TEST_CMD:** ${TEST_CMD:-<skipped>}"
        echo "- **FINISHED:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "## Files"
        echo
        echo '```'
        echo "$files_list"
        echo '```'
        echo
        echo "## Full log"
        echo
        echo "\`.agent-logs/${WORKER_ID}_${task_name}.log\` — otwórz tylko jeśli RESULT != OK."
    } > "$summary_file"
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
    local task_branch="ai-grid/${task_name%.md}"

    log "START: $task_name -> $task_branch (worktree: $WORK_DIR)"

    # 1. Upewnij się że worker ma własny worktree.
    if ! ensure_worktree; then
        return 5
    fi

    # 2. Świeży branch dla taska, na bazowym SHA z głównego repo.
    local base_sha
    base_sha="$(get_base_sha)"
    if [[ -z "$base_sha" ]]; then
        log "BASE: nie znaleziono gałęzi bazowej '$BASE_BRANCH'."
        return 6
    fi
    (
        cd "$WORK_DIR" || exit 7
        # Wyrzuć wszystko z poprzedniego taska (worker reużywa worktree).
        git reset --hard >/dev/null 2>&1 || true
        git clean -fdx >/dev/null 2>&1 || true
        git checkout -B "$task_branch" "$base_sha"
    ) >>"$task_log" 2>&1
    if [[ $? -ne 0 ]]; then
        log "GIT: nie udało się przygotować gałęzi $task_branch."
        return 7
    fi

    # 3. Zbuduj prompt. Treść zadania ląduje w prompcie — gemini nie musi
    #    czytać pliku z dysku (i tak nie jest w worktree).
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
        echo "===== AI OUTPUT (cwd=$WORK_DIR, branch=$task_branch) ====="
    } >"$task_log"

    # 4. Uruchom AI w worktree.
    if ( cd "$WORK_DIR" && printf '%s' "$prompt" | run_ai ) >>"$task_log" 2>&1; then
        log "AI: $task_name — OK."
    else
        local rc=$?
        log "AI: $task_name — BŁĄD (kod $rc)."
        echo "===== AI EXIT CODE: $rc =====" >>"$task_log"
        write_task_summary "AI-FAIL"
        return 1
    fi

    # 5. Opcjonalne testy (w worktree).
    if [[ -n "$TEST_CMD" ]]; then
        log "TEST: '$TEST_CMD' w $WORK_DIR"
        echo "===== TEST OUTPUT ($TEST_CMD) =====" >>"$task_log"
        if ! ( cd "$WORK_DIR" && eval "$TEST_CMD" ) >>"$task_log" 2>&1; then
            log "TEST: $task_name — FAIL. Reset worktree do $base_sha."
            ( cd "$WORK_DIR" && git reset --hard "$base_sha" && git clean -fdx ) >>"$task_log" 2>&1 || true
            write_task_summary "TEST-FAIL"
            return 2
        fi
        log "TEST: PASS."
    else
        log "TEST: pominięty (TEST_CMD pusty)."
    fi

    # 6. Commit w worktree, na gałęzi taska. Brak mutexa — różne gałęzie,
    #    różne working trees, git radzi sobie z równoległymi commitami.
    local commit_subject
    commit_subject=$(extract_commit_subject "$task_path" "$task_name")
    (
        cd "$WORK_DIR" || exit 3
        git add -A
        if git diff --cached --quiet; then
            echo "===== GIT: brak zmian do zacommitowania =====" >>"$task_log"
            exit 10
        fi
        git commit -m "$commit_subject" -m "AI-Grid: ${task_name%.md}" >>"$task_log" 2>&1
    )
    local commit_rc=$?
    case "$commit_rc" in
        0)  log "GIT: commit OK na $task_branch."; write_task_summary "OK" ;;
        10) log "GIT: AI nie wprowadziło zmian — zadanie domknięte bez commita."
            write_task_summary "NO-CHANGES" ;;
        *)  log "GIT: BŁĄD commita ($commit_rc) dla $task_name."
            write_task_summary "COMMIT-FAIL"
            return 3 ;;
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
