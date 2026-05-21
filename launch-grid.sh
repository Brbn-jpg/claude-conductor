#!/usr/bin/env bash
# launch-grid.sh — spawn N parallel AI workers in a tmux session.
#
# Usage:
#   ./launch-grid.sh                # 2 workers (default)
#   ./launch-grid.sh --workers 4    # 4 workers
#   ./launch-grid.sh -w 3
#
# Requirements: tmux on PATH, ./worker-agent.sh executable.

set -euo pipefail

# --- CONFIG -----------------------------------------------------------------

DEFAULT_WORKERS=2
SESSION_NAME="ai-grid"
STALE_LOCK_MINUTES=60          # locks older than X minutes are treated as orphaned

# --- PATHS ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
WORKER_SCRIPT="$REPO_ROOT/worker-agent.sh"
TODO_DIR="$REPO_ROOT/.tasks/todo"
LOCKS_DIR="$REPO_ROOT/.agent-locks"
LOGS_DIR="$REPO_ROOT/.agent-logs"

# --- ARGUMENT PARSING -------------------------------------------------------

WORKERS="$DEFAULT_WORKERS"
NO_ATTACH=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--workers N | -w N] [--no-attach]

Options:
  --workers N, -w N   Number of parallel workers (default: $DEFAULT_WORKERS).
  --no-attach         Create the tmux session and exit (skip 'tmux attach').
                      Useful in CI / when launching from an agent.
                      Inspect later: tmux attach -t $SESSION_NAME
  -h, --help          Show this help.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --workers|-w)
            if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "ERROR: --workers requires a number." >&2
                usage >&2
                exit 2
            fi
            WORKERS="$2"
            shift 2
            ;;
        --workers=*)
            WORKERS="${1#*=}"
            shift
            ;;
        --no-attach)
            NO_ATTACH=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! [[ "$WORKERS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: worker count must be >= 1 (got '$WORKERS')." >&2
    exit 2
fi

# --- SANITY CHECKS ---------------------------------------------------------

if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: 'tmux' not found in PATH. Install tmux and try again." >&2
    exit 1
fi

if [[ ! -x "$WORKER_SCRIPT" ]]; then
    echo "ERROR: $WORKER_SCRIPT is missing or not executable." >&2
    echo "Run: chmod +x $WORKER_SCRIPT" >&2
    exit 1
fi

mkdir -p "$TODO_DIR" "$LOCKS_DIR" "$LOGS_DIR"

# --- 1. STALE LOCK CLEANUP --------------------------------------------------
# Locks are created with `mkdir`, so they're directories. We clean those older
# than STALE_LOCK_MINUTES — protects against the case where a worker crashed
# without firing its trap to release the lock.

if [[ -d "$LOCKS_DIR" ]]; then
    # shellcheck disable=SC2086
    stale_count=$(find "$LOCKS_DIR" -mindepth 1 -maxdepth 1 -name '*.lock' \
                       -mmin +"$STALE_LOCK_MINUTES" 2>/dev/null | wc -l | tr -d ' ')
    if (( stale_count > 0 )); then
        echo "[launch] removing $stale_count orphaned lock(s) (older than ${STALE_LOCK_MINUTES} min)..."
        find "$LOCKS_DIR" -mindepth 1 -maxdepth 1 -name '*.lock' \
             -mmin +"$STALE_LOCK_MINUTES" -exec rm -rf {} + 2>/dev/null || true
    fi
fi

# --- 2. CHECK TASK QUEUE ---------------------------------------------------

shopt -s nullglob
todo_files=( "$TODO_DIR"/*.md )
shopt -u nullglob

# Filter out .keep and hidden files
real_todo=()
for f in "${todo_files[@]}"; do
    bn="$(basename "$f")"
    [[ "$bn" == .* ]] && continue
    real_todo+=( "$f" )
done

if (( ${#real_todo[@]} == 0 )); then
    echo "[launch] No tasks in $TODO_DIR. Add a .md file (see .tasks/_template.md) and try again."
    exit 0
fi

echo "[launch] Found ${#real_todo[@]} task(s) in the queue, starting $WORKERS worker(s) in session '$SESSION_NAME'."

# --- 3. TMUX SESSION -------------------------------------------------------

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "[launch] Session '$SESSION_NAME' already exists."
    echo "[launch] (Fresh start: tmux kill-session -t $SESSION_NAME)"
    if (( NO_ATTACH )); then
        exit 0
    fi
    exec tmux attach -t "$SESSION_NAME"
fi

# Command run in each pane. After the worker exits the pane waits for Enter —
# so you can see final logs instead of an instant close.
build_pane_cmd() {
    local worker_id="$1"
    # printf %q protects against spaces / special chars in paths.
    printf 'cd %q && ./worker-agent.sh %q; echo; echo "[%s finished — press Enter to close pane]"; read -r _' \
        "$REPO_ROOT" "$worker_id" "$worker_id"
}

# Create the session with the first worker.
tmux new-session -d -s "$SESSION_NAME" -n grid "bash -lc $(printf '%q' "$(build_pane_cmd "worker-1")")"

# Add the remaining workers as new panes.
for (( i=2; i<=WORKERS; i++ )); do
    tmux split-window -t "${SESSION_NAME}:grid" \
        "bash -lc $(printf '%q' "$(build_pane_cmd "worker-$i")")"
    # Re-tile after each split so split-window doesn't refuse for lack of room.
    tmux select-layout -t "${SESSION_NAME}:grid" tiled >/dev/null
done

# Final tiled layout + pane titles for orientation.
tmux select-layout -t "${SESSION_NAME}:grid" tiled >/dev/null
tmux set-option -t "$SESSION_NAME" pane-border-status top >/dev/null 2>&1 || true
tmux set-option -t "$SESSION_NAME" pane-border-format ' #{pane_index}: #{pane_title} ' >/dev/null 2>&1 || true

echo "[launch] Session ready."

# --- 4. ATTACH -------------------------------------------------------------

if (( NO_ATTACH )); then
    echo "[launch] --no-attach: session runs in the background. Inspect: tmux attach -t $SESSION_NAME"
    exit 0
fi

echo "[launch] Attaching... (detach: Ctrl-b d)"
exec tmux attach -t "$SESSION_NAME"
