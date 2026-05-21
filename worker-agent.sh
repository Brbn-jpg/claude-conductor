#!/usr/bin/env bash
# worker-agent.sh — a single worker in the AI grid.
#
# Usage: ./worker-agent.sh <WORKER_ID>
#   e.g.  ./worker-agent.sh worker-1
#
# Loop: claim the oldest task from .tasks/todo/, reserve it with an atomic
# mkdir-lock, run AI, optionally run tests, commit, mark done.
# No tasks -> exit. Crash / Ctrl-C -> rollback (task returns to todo/, lock released).

set -uo pipefail

# --- CONFIG -----------------------------------------------------------------

# Test command. Empty = skip verification (commit changes immediately).
# Examples: "npm test", "pytest -q", "go test ./...", "make check".
TEST_CMD="${TEST_CMD:-}"

# Gemini CLI invocation. EASY TO SWAP FOR YOUR OWN TOOL.
# The function reads the prompt on stdin, writes the response to stdout.
#
# Verified with gemini-cli 0.42.0:
#   - `-p/--prompt "<TEXT>"` enables headless (non-interactive) mode
#   - `--yolo` auto-approves ALL model actions (required so the worker
#     can modify files without waiting for confirmation)
#   - `--skip-trust` skips the workspace trust prompt
# Using a different CLI (claude, ollama, llm etc.)? Replace the function body.
run_ai() {
    if ! command -v gemini >/dev/null 2>&1; then
        echo "[run_ai] ERROR: 'gemini' not found in PATH." >&2
        return 127
    fi
    local prompt
    prompt="$(cat)"
    # >>> CHANGE HERE if your CLI has a different syntax. <<<
    gemini --yolo --skip-trust --prompt "$prompt" 2>&1
}

# How often to poll the queue when all visible tasks are locked.
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# --- PATHS ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

TODO_DIR="$REPO_ROOT/.tasks/todo"
IN_PROGRESS_DIR="$REPO_ROOT/.tasks/in_progress"
DONE_DIR="$REPO_ROOT/.tasks/done"
LOCKS_DIR="$REPO_ROOT/.agent-locks"
LOGS_DIR="$REPO_ROOT/.agent-logs"
WORKTREES_DIR="$REPO_ROOT/.worktrees"

# Base branch each new task branches from.
# Default: current branch of the main repo at worker start time.
BASE_BRANCH="${BASE_BRANCH:-$(cd "$REPO_ROOT" && git symbolic-ref --short HEAD 2>/dev/null || echo HEAD)}"

WORKER_ID="${1:-worker-$$}"
WORKER_LOG="$LOGS_DIR/${WORKER_ID}.log"
WORK_DIR="$WORKTREES_DIR/$WORKER_ID"

mkdir -p "$TODO_DIR" "$IN_PROGRESS_DIR" "$DONE_DIR" "$LOCKS_DIR" "$LOGS_DIR" "$WORKTREES_DIR"

# --- GLOBAL STATE (for rollback) -------------------------------------------

CURRENT_LOCK=""        # path to lock directory if owned
CURRENT_TASK_NAME=""   # e.g. task-001.md
CURRENT_IN_PROGRESS="" # path to the file in in_progress/

# --- LOGGING ----------------------------------------------------------------

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%s] %s\n' "$ts" "$WORKER_ID" "$*" | tee -a "$WORKER_LOG"
}

# --- CLEANUP / TRAP --------------------------------------------------------

rollback_current() {
    # Returns the task from in_progress/ back to todo/ and releases the lock.
    # Safe to call even if we hold nothing.
    if [[ -n "$CURRENT_IN_PROGRESS" && -f "$CURRENT_IN_PROGRESS" ]]; then
        local back="$TODO_DIR/$CURRENT_TASK_NAME"
        if mv "$CURRENT_IN_PROGRESS" "$back" 2>/dev/null; then
            log "ROLLBACK: returned $CURRENT_TASK_NAME to todo/"
        else
            log "ROLLBACK: FAILED to return $CURRENT_IN_PROGRESS"
        fi
    fi
    if [[ -n "$CURRENT_LOCK" && -d "$CURRENT_LOCK" ]]; then
        if rmdir "$CURRENT_LOCK" 2>/dev/null; then
            log "ROLLBACK: released lock $(basename "$CURRENT_LOCK")"
        fi
    fi
    CURRENT_LOCK=""
    CURRENT_TASK_NAME=""
    CURRENT_IN_PROGRESS=""
}

on_exit() {
    local code=$?
    if [[ -n "$CURRENT_TASK_NAME" ]]; then
        log "Interrupted while working on $CURRENT_TASK_NAME (exit=$code) — rollback."
        rollback_current
    fi
    log "Worker finished (exit=$code)."
}
trap on_exit EXIT
trap 'log "Received SIGINT/SIGTERM, shutting down..."; exit 130' INT TERM

# --- LOCKING (atomic mkdir) ------------------------------------------------

acquire_lock() {
    # $1 = TASK_NAME (e.g. task-001.md). Success => echo lock path.
    local task_name="$1"
    local lock_path="$LOCKS_DIR/${task_name}.lock"
    # mkdir is atomic on POSIX: only one process gets 0,
    # the rest get EEXIST. This is our race-free guard.
    if mkdir "$lock_path" 2>/dev/null; then
        printf '%s' "$lock_path"
        return 0
    fi
    return 1
}

# Each worker has its own git worktree (.worktrees/<worker-id>). That way
# parallel workers do NOT share a working tree — each worker's gemini operates
# in isolation, and commits land on separate ai-grid/<task-name> branches.
# We can safely skip a global git mutex.

ensure_worktree() {
    # If the worktree already exists, just sanity-check.
    if [[ -e "$WORK_DIR/.git" ]]; then
        return 0
    fi
    log "WORKTREE: creating $WORK_DIR (base=$BASE_BRANCH)"
    if ! ( cd "$REPO_ROOT" && git worktree add --detach "$WORK_DIR" "$BASE_BRANCH" ) >>"$WORKER_LOG" 2>&1; then
        log "WORKTREE: ERROR during 'git worktree add'."
        return 1
    fi
    return 0
}

get_base_sha() {
    ( cd "$REPO_ROOT" && git rev-parse "$BASE_BRANCH" 2>/dev/null )
}

# Extracts the commit subject from the task file.
# Prefers the first H1 (line "# Foo"). If missing or a template placeholder,
# falls back to the filename slug.
extract_commit_subject() {
    local task_file="$1"
    local task_name="$2"

    local h1=""
    if [[ -r "$task_file" ]]; then
        h1=$(grep -m1 '^# ' "$task_file" 2>/dev/null | sed 's/^# *//' | sed 's/[[:space:]]*$//')
    fi

    # Reject template placeholders
    case "$h1" in
        ""|"<Short feature description — THIS becomes the commit message>"|"Research: <short topic description — becomes the commit subject>"|"Task title"|"Research: <topic>")
            # Fallback: slug from filename (task-101-job-electrician.md -> job-electrician)
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

# Writes a concise per-task summary to .agent-logs/<worker>_<task>.summary.md.
# The manager (Claude Code) reads THIS instead of the full log — saves tokens.
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
        echo "\`.agent-logs/${WORKER_ID}_${task_name}.log\` — open only if RESULT != OK."
    } > "$summary_file"
}

# --- TASK CLAIM -----------------------------------------------------------

# Iterates todo/*.md in lexicographic order, tries to claim the first free one.
# Success => sets CURRENT_* and returns 0.
# No files => return 2. All locked => return 1.
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
        # Skip .keep and hidden files
        [[ "$task_name" == .* ]] && continue

        if lock="$(acquire_lock "$task_name")"; then
            # Got the lock — try to move the file to in_progress.
            local dst="$IN_PROGRESS_DIR/$task_name"
            if mv "$file" "$dst" 2>/dev/null; then
                CURRENT_LOCK="$lock"
                CURRENT_TASK_NAME="$task_name"
                CURRENT_IN_PROGRESS="$dst"
                return 0
            else
                # File vanished (e.g. manual intervention) — release lock and continue.
                rmdir "$lock" 2>/dev/null || true
                log "File $task_name disappeared after locking, trying next."
                continue
            fi
        fi
        # Lock held by another worker — skip.
    done
    return 1
}

# --- TASK EXECUTION --------------------------------------------------------

execute_task() {
    local task_path="$CURRENT_IN_PROGRESS"
    local task_name="$CURRENT_TASK_NAME"
    local task_log="$LOGS_DIR/${WORKER_ID}_${task_name}.log"
    local task_branch="ai-grid/${task_name%.md}"

    log "START: $task_name -> $task_branch (worktree: $WORK_DIR)"

    # 1. Make sure the worker has its own worktree.
    if ! ensure_worktree; then
        return 5
    fi

    # 2. Fresh branch for this task, on base SHA from the main repo.
    local base_sha
    base_sha="$(get_base_sha)"
    if [[ -z "$base_sha" ]]; then
        log "BASE: base branch '$BASE_BRANCH' not found."
        return 6
    fi
    (
        cd "$WORK_DIR" || exit 7
        # Clean out everything from the previous task (worker reuses worktree).
        git reset --hard >/dev/null 2>&1 || true
        git clean -fdx >/dev/null 2>&1 || true
        git checkout -B "$task_branch" "$base_sha"
    ) >>"$task_log" 2>&1
    if [[ $? -ne 0 ]]; then
        log "GIT: failed to prepare branch $task_branch."
        return 7
    fi

    # 3. Build the prompt. Task content goes into the prompt — gemini doesn't
    #    need to read the file from disk (it's not in the worktree anyway).
    local prompt
    prompt="$(cat <<EOF
You are a programming expert working in a local repository.
Execute the task below by modifying the appropriate project files.
Strictly follow the "Constraints (Definition of Done)" section.
Do not ask — make the changes. When done, return a short confirmation.

=== TASK CONTENT ($task_name) ===
$(cat "$task_path")
=== END OF TASK ===
EOF
)"

    {
        echo "===== PROMPT ====="
        echo "$prompt"
        echo "===== AI OUTPUT (cwd=$WORK_DIR, branch=$task_branch) ====="
    } >"$task_log"

    # 4. Run AI in the worktree.
    if ( cd "$WORK_DIR" && printf '%s' "$prompt" | run_ai ) >>"$task_log" 2>&1; then
        log "AI: $task_name — OK."
    else
        local rc=$?
        log "AI: $task_name — ERROR (code $rc)."
        echo "===== AI EXIT CODE: $rc =====" >>"$task_log"
        write_task_summary "AI-FAIL"
        return 1
    fi

    # 5. Optional tests (in the worktree).
    if [[ -n "$TEST_CMD" ]]; then
        log "TEST: '$TEST_CMD' in $WORK_DIR"
        echo "===== TEST OUTPUT ($TEST_CMD) =====" >>"$task_log"
        if ! ( cd "$WORK_DIR" && eval "$TEST_CMD" ) >>"$task_log" 2>&1; then
            log "TEST: $task_name — FAIL. Resetting worktree to $base_sha."
            ( cd "$WORK_DIR" && git reset --hard "$base_sha" && git clean -fdx ) >>"$task_log" 2>&1 || true
            write_task_summary "TEST-FAIL"
            return 2
        fi
        log "TEST: PASS."
    else
        log "TEST: skipped (TEST_CMD empty)."
    fi

    # 6. Commit in the worktree, on the task branch. No mutex needed — different
    #    branches, different working trees, git handles concurrent commits.
    local commit_subject
    commit_subject=$(extract_commit_subject "$task_path" "$task_name")
    (
        cd "$WORK_DIR" || exit 3
        git add -A
        if git diff --cached --quiet; then
            echo "===== GIT: nothing to commit =====" >>"$task_log"
            exit 10
        fi
        git commit -m "$commit_subject" -m "AI-Grid: ${task_name%.md}" >>"$task_log" 2>&1
    )
    local commit_rc=$?
    case "$commit_rc" in
        0)  log "GIT: commit OK on $task_branch."; write_task_summary "OK" ;;
        10) log "GIT: AI made no changes — task closed without a commit."
            write_task_summary "NO-CHANGES" ;;
        *)  log "GIT: commit error ($commit_rc) for $task_name."
            write_task_summary "COMMIT-FAIL"
            return 3 ;;
    esac

    return 0
}

# --- MAIN LOOP -------------------------------------------------------------

log "Worker started. REPO=$REPO_ROOT  TEST_CMD='${TEST_CMD:-<none>}'"

while true; do
    if claim_next_task; then
        if execute_task; then
            # Success — move to done/, release lock.
            mv "$CURRENT_IN_PROGRESS" "$DONE_DIR/$CURRENT_TASK_NAME"
            rmdir "$CURRENT_LOCK" 2>/dev/null || true
            log "DONE: $CURRENT_TASK_NAME"
            CURRENT_LOCK=""
            CURRENT_TASK_NAME=""
            CURRENT_IN_PROGRESS=""
        else
            # Failure — rollback (return to todo/, release lock).
            log "FAIL: rollback for $CURRENT_TASK_NAME"
            rollback_current
        fi
    else
        case "$?" in
            2)  log "Queue empty — exiting."; break ;;
            1)  # all visible tasks locked by other workers
                sleep "$POLL_INTERVAL" ;;
        esac
    fi
done

exit 0
