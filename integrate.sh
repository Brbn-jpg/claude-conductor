#!/usr/bin/env bash
# integrate.sh — cherry-pickuje gałęzie ai-grid/* na bieżącą gałąź.
#
# Po sesji workerów masz N gałęzi `ai-grid/<task>`, każda z 1 commitem AI.
# Ten skrypt linearyzuje historię: każdy task → jeden commit na main,
# bez merge-commitów, bez równoległych railsów. Sprząta worktree + gałąź.
#
# Użycie:
#   ./integrate.sh ai-grid/task-101              # pojedyncza gałąź
#   ./integrate.sh task-101                      # bez prefiksu też OK
#   ./integrate.sh --all                         # wszystkie ai-grid/* w kolejności
#   ./integrate.sh --all --dry-run               # podgląd
#   ./integrate.sh --all --keep-branch           # nie kasuj gałęzi po sukcesie

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- ARGS ------------------------------------------------------------------

DRY_RUN=0
KEEP_BRANCH=0
ALL_MODE=0
TARGET=""

usage() {
    cat <<USAGE
Użycie: $(basename "$0") <branch> [opcje]
       $(basename "$0") --all [opcje]

Cherry-pickuje ai-grid/* na bieżącą gałąź (linear history: 1 task = 1 commit).
Po sukcesie usuwa worktree workera + gałąź ai-grid/<task>.

Argumenty:
  <branch>            ai-grid/<task> lub <task> (prefiks dorabiam).

Opcje:
  --all               Wszystkie ai-grid/* w kolejności leksykograficznej
                      (przy zero-padded numerach = chronologicznie).
  --dry-run           Pokaż co by zrobił, nic nie wykonuj.
  --keep-branch       Nie kasuj ai-grid/<task> po cherry-picku (audyt).
  -h, --help          Pomoc.

Zachowanie przy konflikcie:
  STOP. Skrypt wychodzi z kodem 4 i pokazuje co zrobić ręcznie
  (git cherry-pick --continue / --abort). Pozostałe niezintegrowane
  gałęzie zostają nietknięte.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --all)          ALL_MODE=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --keep-branch)  KEEP_BRANCH=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        ai-grid/*)      TARGET="$1"; shift ;;
        task-*|research-*) TARGET="ai-grid/$1"; shift ;;
        -*)             echo "BŁĄD: nieznana flaga '$1'" >&2; usage >&2; exit 2 ;;
        *)              echo "BŁĄD: nieoczekiwany argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

if (( ! ALL_MODE )) && [[ -z "$TARGET" ]]; then
    echo "BŁĄD: podaj <branch> albo --all" >&2
    usage >&2
    exit 2
fi
if (( ALL_MODE )) && [[ -n "$TARGET" ]]; then
    echo "BŁĄD: --all i pojedyncza gałąź wzajemnie się wykluczają" >&2
    exit 2
fi

# --- SANITY ----------------------------------------------------------------

# Czy working tree czysty?
if [[ -n "$(git status --porcelain)" ]]; then
    echo "BŁĄD: working tree nie jest czysty — commit/stash zmiany najpierw." >&2
    git status --short >&2
    exit 3
fi

# Czy nie jesteśmy w środku innej operacji git?
GIT_DIR="$(git rev-parse --git-dir)"
if [[ -f "$GIT_DIR/CHERRY_PICK_HEAD" || -f "$GIT_DIR/MERGE_HEAD" \
   || -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" ]]; then
    echo "BŁĄD: trwająca operacja git (cherry-pick/merge/rebase) — dokończ ją najpierw." >&2
    exit 3
fi

CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo 'DETACHED')"

# --- INTEGRATE ONE ---------------------------------------------------------

integrate_one() {
    local branch="$1"

    if ! git rev-parse --verify --quiet "$branch" >/dev/null; then
        echo "  SKIP: $branch — gałąź nie istnieje"
        return 1
    fi

    local base count
    base=$(git merge-base HEAD "$branch")
    count=$(git rev-list --count "$base..$branch")

    if (( count == 0 )); then
        echo "  SKIP: $branch — brak commitów do integracji (już w HEAD)"
        return 1
    fi

    local tip_sha tip_subject
    tip_sha=$(git rev-parse --short "$branch")
    tip_subject=$(git log -1 --format='%s' "$branch")

    if (( DRY_RUN )); then
        echo "  DRY-RUN: cherry-pick $branch  (${count}x, tip=$tip_sha)  \"$tip_subject\""
        return 0
    fi

    echo "  -> cherry-pick $branch (${count}x)..."
    if ! git cherry-pick --no-edit "$base..$branch"; then
        cat >&2 <<EOF

  KONFLIKT przy $branch. Rozstrzygnij ręcznie:
    git status                     # zobacz konflikty
    \$EDITOR <pliki>                # rozwiąż
    git add <pliki>
    git cherry-pick --continue
  ALBO porzuć:
    git cherry-pick --abort

  Pozostałe niezintegrowane gałęzie zostały nietknięte.
EOF
        return 2
    fi

    local new_sha
    new_sha=$(git rev-parse --short HEAD)
    echo "  OK: $tip_sha -> $new_sha"

    # Sprzątanie worktree (jeśli ten branch jest checkoutowany w którymś)
    local wt
    wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '
        $1=="worktree" { p=$2 }
        $1=="branch"   { if ($2==b) { print p; exit } }
    ')
    if [[ -n "$wt" && "$wt" != "$SCRIPT_DIR" ]]; then
        echo "     ~ usuwam worktree $wt"
        git worktree remove --force "$wt" 2>/dev/null || true
    fi

    if (( ! KEEP_BRANCH )); then
        echo "     ~ usuwam gałąź $branch"
        git branch -D "$branch" >/dev/null
    fi

    return 0
}

# --- MAIN ------------------------------------------------------------------

if (( ALL_MODE )); then
    branches=()
    while IFS= read -r _b; do
        [[ -n "$_b" ]] && branches+=("$_b")
    done < <(git branch --format='%(refname:short)' | grep '^ai-grid/' | sort)

    if (( ${#branches[@]} == 0 )); then
        echo "Brak gałęzi ai-grid/* do integracji."
        exit 0
    fi

    echo "Integrate ${#branches[@]} branches onto $CURRENT_BRANCH:"
    failed=0
    succeeded=0
    for b in "${branches[@]}"; do
        if integrate_one "$b"; then
            ((succeeded++))
        else
            rc=$?
            if (( rc == 2 )); then
                exit 4
            fi
            ((failed++)) || true
        fi
    done
    echo
    echo "Done. ok=$succeeded  skipped=$failed  total=${#branches[@]}"
else
    integrate_one "$TARGET"
fi
