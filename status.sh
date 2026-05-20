#!/usr/bin/env bash
# status.sh — agregowany raport stanu gridu w jednym wywołaniu.
#
# Manager (Claude Code / Ty) wywołuje to ZAMIAST robić 5 osobnych git/ls/tmux
# komend. Daje pełny obraz: kolejka, gałęzie ai-grid/*, podejrzanie duże diffy,
# locki, sesje tmux, ostatnie summary.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

BASE_BRANCH="${BASE_BRANCH:-$(git symbolic-ref --short HEAD 2>/dev/null || echo main)}"
LARGE_DIFF_LINES="${LARGE_DIFF_LINES:-100}"

count_md() {
    ls "$1" 2>/dev/null | grep -v '^\.keep$' | grep -E '\.md$' | wc -l | tr -d ' '
}

list_md() {
    ls "$1" 2>/dev/null | grep -v '^\.keep$' | grep -E '\.md$' || true
}

echo "================== claude-conductor status =================="
echo "BASE_BRANCH:        $BASE_BRANCH"
echo "LARGE_DIFF_LINES:   $LARGE_DIFF_LINES"
echo

# --- Kolejka -----------------------------------------------------------------
echo "QUEUE:"
echo "  todo         ($(count_md .tasks/todo)):"
list_md .tasks/todo | sed 's/^/    - /'
echo "  in_progress  ($(count_md .tasks/in_progress)):"
list_md .tasks/in_progress | sed 's/^/    - /'
echo "  done         ($(count_md .tasks/done)):"
list_md .tasks/done | sed 's/^/    - /'

# --- Gałęzie ai-grid/* -------------------------------------------------------
echo
echo "BRANCHES (ai-grid/*):"
branches=()
while IFS= read -r _b; do branches+=("$_b"); done < <(git branch --format='%(refname:short)' 2>/dev/null | grep '^ai-grid/' || true)
if (( ${#branches[@]} == 0 )); then
    echo "  (none)"
else
    for b in "${branches[@]}"; do
        if git rev-parse --verify --quiet "$BASE_BRANCH" >/dev/null; then
            stat="$(git diff --shortstat "$BASE_BRANCH..$b" 2>/dev/null | sed 's/^ *//')"
        else
            stat="(base $BASE_BRANCH not found)"
        fi
        lines=$(echo "$stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
        marker=""
        if [[ -n "$lines" && "$lines" -gt "$LARGE_DIFF_LINES" ]]; then
            marker="  [LARGE — review]"
        fi
        commit="$(git log -1 --format='%h' "$b" 2>/dev/null || echo '-')"
        echo "  $b  @ $commit  — ${stat:-no diff}$marker"
    done
fi

# --- Locki -------------------------------------------------------------------
echo
echo "LOCKS:"
locks=()
while IFS= read -r _l; do locks+=("$_l"); done < <(ls .agent-locks 2>/dev/null | grep -v '^\.keep$' || true)
if (( ${#locks[@]} == 0 )); then
    echo "  clean"
else
    echo "  ${#locks[@]} active:"
    for l in "${locks[@]}"; do
        age=$(find ".agent-locks/$l" -mmin +60 2>/dev/null | wc -l | tr -d ' ')
        flag=""
        (( age > 0 )) && flag="  [STALE >60min]"
        echo "    - $l$flag"
    done
fi

# --- Sesja tmux --------------------------------------------------------------
echo
echo "TMUX:"
if tmux has-session -t ai-grid 2>/dev/null; then
    panes=$(tmux list-panes -t ai-grid 2>/dev/null | wc -l | tr -d ' ')
    echo "  ai-grid session running ($panes panes)"
else
    echo "  no ai-grid session"
fi

# --- Ostatnie summary --------------------------------------------------------
echo
echo "RECENT SUMMARIES (5 last):"
summaries=()
while IFS= read -r _s; do summaries+=("$_s"); done < <(ls -t .agent-logs/*.summary.md 2>/dev/null | head -5 || true)
if (( ${#summaries[@]} == 0 )); then
    echo "  (none yet)"
else
    for s in "${summaries[@]}"; do
        result=$(grep -E '^\- \*\*RESULT:\*\*' "$s" | head -1 | sed 's/.*RESULT:\*\* //')
        echo "  - $(basename "$s")  → ${result:-?}"
    done
fi

# --- Worktrees ---------------------------------------------------------------
echo
echo "WORKTREES:"
git worktree list 2>/dev/null | sed 's/^/  /' || echo "  (none)"
