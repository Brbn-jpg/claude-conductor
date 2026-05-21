#!/usr/bin/env bash
# integrate.sh — cherry-pick ai-grid/* branches onto the current branch.
#
# After a worker session you have N ai-grid/<task> branches, each with 1 AI commit.
# This script linearizes history: each task -> one commit on main, no merge
# commits, no parallel rails. Cleans up the worktree + branch on success.
#
# Usage:
#   ./integrate.sh ai-grid/task-101              # single branch
#   ./integrate.sh task-101                      # prefix added for you
#   ./integrate.sh --all                         # all ai-grid/* in order
#   ./integrate.sh --all --dry-run               # preview
#   ./integrate.sh --all --keep-branch           # don't delete ai-grid/<task> on success

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
Usage: $(basename "$0") <branch> [options]
       $(basename "$0") --all [options]

Cherry-picks ai-grid/* onto the current branch (linear history:
1 task = 1 commit). After success removes the worker's worktree
and the ai-grid/<task> branch.

Arguments:
  <branch>            ai-grid/<task> or <task> (prefix added for you).

Options:
  --all               All ai-grid/* in lexicographic order
                      (with zero-padded task numbers = chronological).
  --dry-run           Show what would happen, don't execute.
  --keep-branch       Don't delete ai-grid/<task> after cherry-pick (audit).
  -h, --help          Show help.

Conflict behavior:
  STOP. Script exits with code 4 and prints what to do manually
  (git cherry-pick --continue / --abort). Remaining un-integrated
  branches are left untouched.
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
        -*)             echo "ERROR: unknown flag '$1'" >&2; usage >&2; exit 2 ;;
        *)              echo "ERROR: unexpected argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

if (( ! ALL_MODE )) && [[ -z "$TARGET" ]]; then
    echo "ERROR: pass <branch> or --all" >&2
    usage >&2
    exit 2
fi
if (( ALL_MODE )) && [[ -n "$TARGET" ]]; then
    echo "ERROR: --all and a specific branch are mutually exclusive" >&2
    exit 2
fi

# --- SANITY ----------------------------------------------------------------

# Working tree clean?
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree is not clean — commit/stash changes first." >&2
    git status --short >&2
    exit 3
fi

# Not in the middle of another git operation?
GIT_DIR="$(git rev-parse --git-dir)"
if [[ -f "$GIT_DIR/CHERRY_PICK_HEAD" || -f "$GIT_DIR/MERGE_HEAD" \
   || -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" ]]; then
    echo "ERROR: git operation in progress (cherry-pick/merge/rebase) — finish it first." >&2
    exit 3
fi

CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo 'DETACHED')"

# --- INTEGRATE ONE ---------------------------------------------------------

integrate_one() {
    local branch="$1"

    if ! git rev-parse --verify --quiet "$branch" >/dev/null; then
        echo "  SKIP: $branch — branch does not exist"
        return 1
    fi

    local base count
    base=$(git merge-base HEAD "$branch")
    count=$(git rev-list --count "$base..$branch")

    if (( count == 0 )); then
        echo "  SKIP: $branch — no commits to integrate (already in HEAD)"
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

  CONFLICT on $branch. Resolve manually:
    git status                     # see conflicts
    \$EDITOR <files>                # resolve
    git add <files>
    git cherry-pick --continue
  Or abort:
    git cherry-pick --abort

  Remaining un-integrated branches are left untouched.
EOF
        return 2
    fi

    local new_sha
    new_sha=$(git rev-parse --short HEAD)
    echo "  OK: $tip_sha -> $new_sha"

    # Cleanup the worktree (if this branch is checked out in any of them)
    local wt
    wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '
        $1=="worktree" { p=$2 }
        $1=="branch"   { if ($2==b) { print p; exit } }
    ')
    if [[ -n "$wt" && "$wt" != "$SCRIPT_DIR" ]]; then
        echo "     ~ removing worktree $wt"
        git worktree remove --force "$wt" 2>/dev/null || true
    fi

    if (( ! KEEP_BRANCH )); then
        echo "     ~ deleting branch $branch"
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
        echo "No ai-grid/* branches to integrate."
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
