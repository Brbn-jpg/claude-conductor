# claude-conductor

> **Run N AI agents in parallel. Bash + tmux + gemini CLI. No frameworks.**

Drop tasks into `.tasks/todo/` as Markdown files. `./launch-grid.sh --workers N` spawns N parallel workers in a `tmux` session — each in **its own git worktree**, each commit on **its own branch** `ai-grid/<task>`. After workers finish, you (as the manager) merge what's good.

No Docker, no Python stacks, no orchestrators. The lock file is a directory created with `mkdir`. The queue is a directory of `.md` files. That's it.

## Why?

You have a batch of small, **independent** tasks — "add 5 tests to these endpoints", "generate fixtures for 12 models", "write 8 READMEs for the submodules"? Instead of waiting for one AI instance to grind through them sequentially, spawn N workers. Because gemini-cli (or any other CLI after swapping one function) in `--yolo` mode can operate on a repo unattended, but only if each instance has **its own sandbox**. Hence: worktree per worker.

## What it looks like

```
                    +--------------------+
        Manager  -> |  .tasks/todo/      |   (queue)
                    +---------+----------+
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
  |   (tmux)  |         |   (tmux)  |         |   (tmux)  |
  +-----+-----+         +-----+-----+         +-----+-----+
        |                     |                     |
   mkdir-lock            mkdir-lock            mkdir-lock
        |                     |                     |
        v                     v                     v
  .worktrees/            .worktrees/           .worktrees/
   worker-1/              worker-2/             worker-N/
   gemini --yolo          gemini --yolo         gemini --yolo
        |                     |                     |
   git commit -->         git commit -->        git commit -->
   ai-grid/task-A         ai-grid/task-B        ai-grid/task-C
        \_____________________|_____________________/
                              |
                              v
                  Manager integrates
                  whatever passes review
```

## Requirements

- `bash` (4+ works, 5+ recommended)
- `git`
- `tmux` (`brew install tmux` / `apt install tmux`)
- [gemini CLI](https://github.com/google-gemini/gemini-cli), authenticated — tested on 0.42.0. Just need `gemini` on PATH and a one-time `gemini auth login`.

Not using gemini? Swap the body of the `run_ai()` function at the top of `worker-agent.sh` — that's it — works with any CLI that takes a prompt and writes files (claude-code, ollama, llm, etc.).

## Quickstart

```bash
git clone https://github.com/Brbn-jpg/claude-conductor.git
cd claude-conductor

# 1. Create a task from the template
cp .tasks/_template.md .tasks/todo/task-001-my-task.md
$EDITOR .tasks/todo/task-001-my-task.md   # fill in Goal / Context / Files / DoD

# 2. Launch the grid (default 2 workers)
./launch-grid.sh --workers 2
# Ctrl-b d — detach from session   |   tmux attach -t ai-grid — reattach

# 3. See what the workers did
./status.sh                             # one-shot overview
git log -p ai-grid/task-001-my-task     # diff for a specific branch

# 4. Integrate (cherry-pick, linear history, cleans worktree + branch)
./integrate.sh --all                    # everything onto current branch
git branch -D ai-grid/task-001-my-task  # optional, integrate.sh already removes it
```

Headless mode (CI / another script):

```bash
./launch-grid.sh --workers 3 --no-attach
# session runs in the background; inspect: tmux attach -t ai-grid
```

## How it works

Three mechanisms that make this work:

1. **Atomic locks via `mkdir`** — workers seeing the same file in the queue never claim it concurrently. `mkdir foo.lock` is atomic on POSIX: only one process gets exit 0, the rest get `EEXIST`. No `flock`, no SQL, no Redis.

2. **Worktree per worker** — `git worktree add --detach .worktrees/<worker-id> $BASE_BRANCH`. Gemini in `--yolo` writes files there, not in the main repo. No shared working tree = no race on `git add -A`.

3. **Branch per task** — before each task the worker runs `git checkout -B ai-grid/<task-name> $BASE_SHA` inside its worktree. The commit lands on an isolated branch. After the session, merge what's good, drop the rest.

**Crash-safe**: `trap EXIT` in the worker returns the task from `in_progress/` to `todo/` and releases the lock on SIGINT/SIGTERM/exception. `launch-grid.sh` cleans locks older than 60 minutes at startup (for workers that died before their trap could fire).

## Project layout

| Path | Role |
|---|---|
| `launch-grid.sh` | Orchestrator: lock cleanup, tmux session, `N` worker panes |
| `worker-agent.sh` | Single worker loop: claim -> AI -> tests -> commit -> done |
| `status.sh` | Aggregated grid status in one call (queue, branches, locks, summaries) |
| `integrate.sh` | Cherry-pick `ai-grid/*` onto current branch (1 task = 1 commit, no merge commits) + cleanup worktree/branch |
| `.tasks/_template.md` | Code task template (Goal / Context / Files / DoD) |
| `.tasks/_template-research.md` | Research task template (gemini explores the codebase, writes a report instead of changing code) |
| `.tasks/todo/` | Pending tasks |
| `.tasks/in_progress/` | Tasks being processed |
| `.tasks/done/` | Completed tasks (audit) |
| `.agent-locks/` | Atomic `mkdir` locks per task |
| `.agent-logs/` | Logs: `<worker>.log`, `<worker>_<task>.log` (full AI output), `<worker>_<task>.summary.md` (concise per-task report — manager reads this instead of the full log) |
| `.worktrees/<worker-id>/` | Isolated worktree per worker (runtime, gitignored) |
| `CLAUDE.md` | Instructions for Claude Code (when using it as the manager) |

## Configuration

All knobs are in the first ~30 lines of `worker-agent.sh`:

| Variable | Default | Description |
|---|---|---|
| `TEST_CMD` | `""` | Test command run after AI. Empty = skip. Examples: `"npm test"`, `"pytest -q"`, `"go test ./..."`. On failure: reset worktree, task returns to `todo/`. |
| `POLL_INTERVAL` | `5` | Seconds between attempts to claim a task when all visible ones are locked. |
| `BASE_BRANCH` | current branch | Branch each task starts from for `ai-grid/<task>`. |
| `run_ai()` | `gemini --yolo --skip-trust --prompt …` | **Adapter function.** Swap the body to use a different CLI. |

`launch-grid.sh`:
- `--workers N` / `-w N` — number of panes (default 2)
- `--no-attach` — create session and exit without `tmux attach` (useful in CI)

## Parallelism safety

| Mechanism | What it solves |
|---|---|
| **Atomic `mkdir` lock** | Two workers seeing the same file in `todo/` — only one wins `mkdir .agent-locks/<task>.lock` (POSIX guarantees atomicity). |
| **Worktree per worker** | No shared working tree -> no race when gemini writes files and `git add -A` runs. Each worker = its own `.worktrees/<worker-id>`. |
| **Branch per task** | Each commit lands on `ai-grid/<task-name>`, so `git add -A` in one worktree doesn't pull in another worker's changes. |
| **Trap rollback** | SIGINT/SIGTERM/crash -> task returns from `in_progress/` to `todo/`, lock released, worker exits cleanly. |
| **Stale lock cleanup** | `launch-grid.sh` removes locks older than 60 min at startup (for workers that crashed without firing their trap). |

## tmux cheatsheet

```bash
tmux attach -t ai-grid             # attach to a running session
# inside tmux:
#   Ctrl-b d        — detach (session keeps running)
#   Ctrl-b <arrow>  — jump between panes
#   Ctrl-b z        — zoom into a single pane
tmux list-panes -t ai-grid         # inspect panes from outside
tmux capture-pane -t ai-grid:grid.0 -p   # dump pane 0 contents
tmux kill-session -t ai-grid       # kill the whole session
```

## Cleanup after a session

By default, `./integrate.sh` does this for you after each success (worktree + branch). Manually only when you want to discard results without integrating:

```bash
git worktree list                              # see active worktrees
git worktree remove --force .worktrees/worker-1
git branch -D ai-grid/task-XXX

# Reset a whole session (all worker worktrees + ai-grid branches):
git worktree list | awk '/.worktrees\// {print $1}' | xargs -n1 git worktree remove --force
git branch | awk '/ai-grid\//{print $1}' | xargs -r git branch -D
```

## Known limitations

- **Workers exit when `todo/` is empty.** If you want a "daemon" that stays up until `Ctrl-c`, replace `break` in the main loop of `worker-agent.sh` with `sleep "$POLL_INTERVAL"; continue`.
- **No retry counter** — task crashes after AI failure return to the queue with no limit. In practice gemini is stable, but for production add a cap.
- **Stale-lock cleanup** is hardcoded to 60 min. For long-running tasks, bump `STALE_LOCK_MINUTES` in `launch-grid.sh`.
- **`--yolo` = full trust in the AI.** The framework isolates workers via worktrees, but the prompt won't write itself: task quality (DoD) determines output quality. Stick to the template.
- **Lexicographic queue order by default** — workers pick files lexicographically from `todo/`. If you need priorities, prefix names (`task-001-`, `task-002-`).

## Bonus: working with Claude Code

The repo includes [`CLAUDE.md`](CLAUDE.md) with instructions for [Claude Code](https://claude.com/claude-code) in "Manager + Workers" mode: Claude breaks a big problem into atomic tasks in `.tasks/todo/`, you say "launch the grid", Claude asks for review of `[AI-Grid]` commits and permission to push. Not using Claude Code? Everything works identically by hand — you write tasks, you merge.

## License

[MIT](LICENSE) © 2026 Jakub Kuźnicki
