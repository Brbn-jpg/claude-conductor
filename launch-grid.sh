#!/usr/bin/env bash
# launch-grid.sh — odpala N równoległych workerów AI w sesji tmux.
#
# Użycie:
#   ./launch-grid.sh                # 2 workery (domyślnie)
#   ./launch-grid.sh --workers 4    # 4 workery
#   ./launch-grid.sh -w 3
#
# Wymagania: tmux w PATH, ./worker-agent.sh wykonywalny.

set -euo pipefail

# --- KONFIGURACJA -----------------------------------------------------------

DEFAULT_WORKERS=2
SESSION_NAME="ai-grid"
STALE_LOCK_MINUTES=60          # locki starsze niż X minut traktujemy jak osierocone

# --- ŚCIEŻKI ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
WORKER_SCRIPT="$REPO_ROOT/worker-agent.sh"
TODO_DIR="$REPO_ROOT/.tasks/todo"
LOCKS_DIR="$REPO_ROOT/.agent-locks"
LOGS_DIR="$REPO_ROOT/.agent-logs"

# --- PARSOWANIE ARGUMENTÓW --------------------------------------------------

WORKERS="$DEFAULT_WORKERS"
NO_ATTACH=0

usage() {
    cat <<USAGE
Użycie: $(basename "$0") [--workers N | -w N] [--no-attach]

Opcje:
  --workers N, -w N   Liczba równoległych workerów (domyślnie: $DEFAULT_WORKERS).
  --no-attach         Stwórz sesję tmux i wyjdź (bez 'tmux attach').
                      Przydatne w CI / przy uruchamianiu z poziomu agenta.
                      Sesję obejrzysz: tmux attach -t $SESSION_NAME
  -h, --help          Pokaż tę pomoc.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --workers|-w)
            if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "BŁĄD: --workers wymaga liczby." >&2
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
            echo "BŁĄD: nieznany argument '$1'." >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! [[ "$WORKERS" =~ ^[1-9][0-9]*$ ]]; then
    echo "BŁĄD: liczba workerów musi być >= 1 (dostałem '$WORKERS')." >&2
    exit 2
fi

# --- SANITY CHECKS ---------------------------------------------------------

if ! command -v tmux >/dev/null 2>&1; then
    echo "BŁĄD: brak 'tmux' w PATH. Zainstaluj tmux i spróbuj ponownie." >&2
    exit 1
fi

if [[ ! -x "$WORKER_SCRIPT" ]]; then
    echo "BŁĄD: $WORKER_SCRIPT nie istnieje albo nie jest wykonywalny." >&2
    echo "Wykonaj: chmod +x $WORKER_SCRIPT" >&2
    exit 1
fi

mkdir -p "$TODO_DIR" "$LOCKS_DIR" "$LOGS_DIR"

# --- 1. SPRZĄTANIE STARYCH LOCKÓW ------------------------------------------
# Locki tworzymy przez `mkdir`, więc są katalogami. Czyścimy te starsze niż
# STALE_LOCK_MINUTES — chronimy się przed sytuacją po crashu workera, który
# nie zdążył zwolnić swojego locka w trapie.

if [[ -d "$LOCKS_DIR" ]]; then
    # shellcheck disable=SC2086
    stale_count=$(find "$LOCKS_DIR" -mindepth 1 -maxdepth 1 -name '*.lock' \
                       -mmin +"$STALE_LOCK_MINUTES" 2>/dev/null | wc -l | tr -d ' ')
    if (( stale_count > 0 )); then
        echo "[launch] usuwam $stale_count osieroconych locków (starszych niż ${STALE_LOCK_MINUTES} min)..."
        find "$LOCKS_DIR" -mindepth 1 -maxdepth 1 -name '*.lock' \
             -mmin +"$STALE_LOCK_MINUTES" -exec rm -rf {} + 2>/dev/null || true
    fi
fi

# --- 2. SPRAWDŹ KOLEJKĘ ZADAŃ ----------------------------------------------

shopt -s nullglob
todo_files=( "$TODO_DIR"/*.md )
shopt -u nullglob

# Wyfiltruj .keep i ukryte
real_todo=()
for f in "${todo_files[@]}"; do
    bn="$(basename "$f")"
    [[ "$bn" == .* ]] && continue
    real_todo+=( "$f" )
done

if (( ${#real_todo[@]} == 0 )); then
    echo "[launch] Brak zadań w $TODO_DIR. Dodaj plik .md (patrz .tasks/_template.md) i odpal ponownie."
    exit 0
fi

echo "[launch] Znaleziono ${#real_todo[@]} zadań w kolejce, startuję $WORKERS workerów w sesji '$SESSION_NAME'."

# --- 3. SESJA TMUX ---------------------------------------------------------

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "[launch] Sesja '$SESSION_NAME' już istnieje."
    echo "[launch] (Świeży start: tmux kill-session -t $SESSION_NAME)"
    if (( NO_ATTACH )); then
        exit 0
    fi
    exec tmux attach -t "$SESSION_NAME"
fi

# Komenda uruchamiana w każdym panelu. Po zakończeniu workera pane czeka
# na Enter — dzięki temu widzisz końcowe logi zamiast natychmiastowego close'u.
build_pane_cmd() {
    local worker_id="$1"
    # printf %q chroni przed spacjami / znakami specjalnymi w ścieżkach.
    printf 'cd %q && ./worker-agent.sh %q; echo; echo "[%s zakończył — Enter zamyka panel]"; read -r _' \
        "$REPO_ROOT" "$worker_id" "$worker_id"
}

# Utwórz sesję z pierwszym workerem.
tmux new-session -d -s "$SESSION_NAME" -n grid "bash -lc $(printf '%q' "$(build_pane_cmd "worker-1")")"

# Dorzuć kolejne workery jako nowe panele.
for (( i=2; i<=WORKERS; i++ )); do
    tmux split-window -t "${SESSION_NAME}:grid" \
        "bash -lc $(printf '%q' "$(build_pane_cmd "worker-$i")")"
    # Po każdym splicie wyrównujemy layout, żeby split-window nie odmawiał z braku miejsca.
    tmux select-layout -t "${SESSION_NAME}:grid" tiled >/dev/null
done

# Ostateczne ułożenie kafelkowe + tytuły paneli ułatwiające orientację.
tmux select-layout -t "${SESSION_NAME}:grid" tiled >/dev/null
tmux set-option -t "$SESSION_NAME" pane-border-status top >/dev/null 2>&1 || true
tmux set-option -t "$SESSION_NAME" pane-border-format ' #{pane_index}: #{pane_title} ' >/dev/null 2>&1 || true

echo "[launch] Sesja gotowa."

# --- 4. ATTACH -------------------------------------------------------------

if (( NO_ATTACH )); then
    echo "[launch] --no-attach: sesja działa w tle. Obejrzyj: tmux attach -t $SESSION_NAME"
    exit 0
fi

echo "[launch] Podłączam się... (odłącz: Ctrl-b d)"
exec tmux attach -t "$SESSION_NAME"
