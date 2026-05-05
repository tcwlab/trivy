#!/usr/bin/env bash
# claude-git.sh — Per-repo git wrapper.
#
# Remote: ssh://git@git.mon.k8b.co:2222/tcwlab/trivy.git
#
# Operates on the .git of this single repo (every repo is its own git
# repo, this is not a monorepo). Invoked from the higher orchestrator
# layers (../claude-git.sh and ../../claude-git.sh), but works
# standalone when running directly inside the repo folder.
#
# Conventional Commits 1.0 are mandatory. On main/master the wrapper
# auto-switches to a claude/<slug> branch.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERTICAL_NAME="$(basename "$REPO_ROOT")"
PROJECT_NAME="$(basename "$(dirname "$REPO_ROOT")")"
DISPLAY="$PROJECT_NAME/$VERTICAL_NAME"

# Allowed Conventional Commits types
readonly CC_TYPES='feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert'

# ──────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────

# Removes stale .git/*.lock files that the Cowork sandbox cannot delete
# itself on the virtiofs mount. Called before every git operation so
# that follow-up Mac-side operations do not silently hang on a stale
# index.lock. Idempotent, defensive, silent when there is nothing to do.
cleanup_stale_locks() {
    local repo_dir="$1"
    [ -d "$repo_dir/.git" ] || return 0

    # Important: find -delete can fail on some mounts (e.g. virtiofs in
    # the Cowork sandbox). The wrapper operation must NOT abort because
    # of that — therefore '|| true' on every find call and stderr
    # redirected to /dev/null. On the Mac (where this wrapper primarily
    # runs) the deletes succeed and everything is fine; in the sandbox
    # virtiofs may block, but git ignores the sandbox-side locks once
    # the Mac-side cleanup has taken effect again.

    # Standard locks (index, HEAD, *.stuck.*, *.stale-*)
    find "$repo_dir/.git" -maxdepth 3 \( \
           -name 'index.lock' \
        -o -name 'HEAD.lock' \
        -o -name '*.lock.stale-*' \
        -o -name '*.stale-*' \
        -o -name '*.lock.stuck.*' \
        -o -name '*.stuck.*' \
    \) -type f -delete 2>/dev/null || true

    # Maintenance locks inside objects/
    find "$repo_dir/.git/objects" -name 'maintenance.lock' -type f -delete 2>/dev/null || true

    # Ref locks (tags, branches)
    find "$repo_dir/.git/refs" -name '*.lock' -type f -delete 2>/dev/null || true

    # CI-pipe locks (from CI scripts or stash operations)
    find "$repo_dir/.git" -maxdepth 2 -name '*.tmp.*.lock' -type f -delete 2>/dev/null || true

    return 0
}

# Verbose variant for the explicit cleanup command — reports what was
# removed and what could not be removed (typical on virtiofs).
cleanup_stale_locks_verbose() {
    local repo_dir="$1"
    [ -d "$repo_dir/.git" ] || { echo "ℹ️  '$DISPLAY': no .git — nothing to do."; return 0; }

    local found=()
    while IFS= read -r f; do
        [ -n "$f" ] && found+=("$f")
    done < <(
        {
            find "$repo_dir/.git" -maxdepth 3 \( \
                   -name 'index.lock' \
                -o -name 'HEAD.lock' \
                -o -name '*.lock.stale-*' \
                -o -name '*.stale-*' \
                -o -name '*.lock.stuck.*' \
                -o -name '*.stuck.*' \
            \) -type f 2>/dev/null
            find "$repo_dir/.git/objects" -name 'maintenance.lock' -type f 2>/dev/null
            find "$repo_dir/.git/refs" -name '*.lock' -type f 2>/dev/null
            find "$repo_dir/.git" -maxdepth 2 -name '*.tmp.*.lock' -type f 2>/dev/null
        } || true
    )

    cleanup_stale_locks "$repo_dir"

    # After the cleanup, check what really went away — on the virtiofs
    # mount the delete may block, in which case we list those files as
    # "not removed" rather than falsely claiming everything is clean.
    local removed=() still_there=()
    local f
    for f in "${found[@]}"; do
        if [ -e "$f" ]; then
            still_there+=("$f")
        else
            removed+=("$f")
        fi
    done

    if [ "${#found[@]}" -eq 0 ]; then
        echo "✓ '$DISPLAY': no stale locks."
        return 0
    fi

    if [ "${#removed[@]}" -gt 0 ]; then
        echo "✓ '$DISPLAY': removed ${#removed[@]} stale lock(s):"
        for f in "${removed[@]}"; do
            echo "    .git/${f#"$repo_dir/.git/"}"
        done
    fi
    if [ "${#still_there[@]}" -gt 0 ]; then
        echo "⚠️  '$DISPLAY': could not remove ${#still_there[@]} lock(s) (virtiofs?):"
        for f in "${still_there[@]}"; do
            echo "    .git/${f#"$repo_dir/.git/"}"
        done
    fi
}

is_git_repo() {
    [ -d "$REPO_ROOT/.git" ] || git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1
}

require_git_repo() {
    if ! is_git_repo; then
        cat >&2 <<EOF
❌ '$DISPLAY' is not (yet) a git repo.

Initialize or clone first:
   cd "$REPO_ROOT"
   git init                              # new empty repo
   # or
   git clone <forgejo-url> .             # fetch existing repo

The orchestrator scripts will then pick this repo up automatically.
EOF
        return 1
    fi
}

validate_conventional_commit() {
    local msg="$1"
    local first_line
    first_line="$(printf '%s\n' "$msg" | head -n1)"
    local pattern="^(${CC_TYPES})(\\([^)]+\\))?!?: .+"
    if [[ ! "$first_line" =~ $pattern ]]; then
        cat >&2 <<EOF
❌ Commit message violates Conventional Commits 1.0:
   '$first_line'

Expected format:
   <type>(<scope>)?!?: <description>

Allowed types:
   feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert

Examples:
   feat: add user login
   feat(auth): add OIDC support
   fix!: drop legacy API
   chore(deps): bump axios
EOF
        return 1
    fi
    return 0
}

slug_from_description() {
    # Build a slug from the commit description (lowercase, [a-z0-9-], max 40 chars).
    local desc="$1"
    local s
    s="$(printf '%s' "$desc" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    s="${s:0:40}"
    s="$(printf '%s' "$s" | sed -E 's/-+$//')"
    printf '%s' "$s"
}

extract_description() {
    # Pull the description part after the first ': ' from the header line.
    local first_line="$1"
    printf '%s' "$first_line" | sed -E 's/^[^:]+: //'
}

current_branch() {
    git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

# Returns 0 if a switch to the target branch is safe, 1 if it would
# clobber local changes (and prints a clear stderr message in that case).
#
# This guard exists because of the branch drift we hit twice in the past:
# a failed `git checkout main` was treated as a mere hint and the wrapper
# happily kept committing on the old claude/<X> branch (see memory:
# feedback_git_wrapper_…).
check_clean_worktree_for_switch() {
    local target="$1"
    local repo="$REPO_ROOT"

    # Already on the target? Nothing to do.
    local current
    current="$(current_branch)"
    if [ "$current" = "$target" ]; then
        return 0
    fi

    # Working tree clean? Then any switch is safe.
    if [ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
        return 0
    fi

    # Dirty. Check whether the switch actually causes a conflict.
    # If the target exists neither locally nor remotely, `git checkout
    # -b $target` creates a NEW branch from the current HEAD — that
    # cannot lose changes.
    local target_ref=""
    if git -C "$repo" rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
        target_ref="$target"
    elif git -C "$repo" rev-parse --verify --quiet "origin/$target" >/dev/null 2>&1; then
        target_ref="origin/$target"
    else
        # Branch does not exist → will be created from HEAD → safe.
        return 0
    fi

    # Dirty files (modified + staged) — these cause trouble when their
    # content differs between HEAD and the target.
    local dirty_modified
    dirty_modified="$(
        {
            git -C "$repo" diff --name-only 2>/dev/null
            git -C "$repo" diff --cached --name-only 2>/dev/null
        } | sed '/^$/d' | sort -u
    )"

    # Files that differ between HEAD and the target.
    local switch_changed
    switch_changed="$(git -C "$repo" diff --name-only HEAD "$target_ref" 2>/dev/null | sed '/^$/d' | sort -u)"

    # Untracked files — only a problem when the target has a tracked
    # file with the same path.
    local dirty_untracked
    dirty_untracked="$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null | sed '/^$/d' | sort -u)"

    local target_tracked
    target_tracked="$(git -C "$repo" ls-tree -r --name-only "$target_ref" 2>/dev/null | sed '/^$/d' | sort -u)"

    # Intersection check via comm.
    local conflicts_modified conflicts_untracked
    conflicts_modified="$(comm -12 <(printf '%s\n' "$dirty_modified") <(printf '%s\n' "$switch_changed") 2>/dev/null)"
    conflicts_untracked="$(comm -12 <(printf '%s\n' "$dirty_untracked") <(printf '%s\n' "$target_tracked") 2>/dev/null)"

    if [ -z "$conflicts_modified" ] && [ -z "$conflicts_untracked" ]; then
        # Dirty but no conflict — git checkout would succeed (the
        # changes travel with the worktree onto the target branch).
        return 0
    fi

    # Conflict case.
    {
        echo "❌ '$DISPLAY': branch switch '$current' → '$target' would lose local changes."
        if [ -n "$conflicts_modified" ]; then
            echo ""
            echo "   Modified files that collide between branches:"
            printf '%s\n' "$conflicts_modified" | sed 's/^/      /'
        fi
        if [ -n "$conflicts_untracked" ]; then
            echo ""
            echo "   Untracked files that the target would overwrite:"
            printf '%s\n' "$conflicts_untracked" | sed 's/^/      /'
        fi
        echo ""
        echo "   Options:"
        echo "      a) Commit on '$current' first, then retry:"
        echo "         ./claude-git.sh commit \"<conventional-msg>\""
        echo "         ./claude-git.sh branch $target"
        echo ""
        echo "      b) Stash + switch + pop manually:"
        echo "         git -C \"$REPO_ROOT\" stash push --include-untracked -m 'before-switch'"
        echo "         ./claude-git.sh branch $target"
        echo "         git -C \"$REPO_ROOT\" stash pop"
        echo ""
        echo "      c) Wrapper auto-stash (side-effect: leaves a stash entry):"
        echo "         ./claude-git.sh branch --auto-stash $target"
    } >&2
    return 1
}

# Inspects the current branch before a commit. If the branch is a stale
# claude/<X> (already merged into main, or deleted on origin), abort
# with a non-zero exit — unless the caller explicitly passed --force.
#
# The heuristic uses `git cherry main claude/X` (patch-id equivalence,
# which catches squash merges) plus `git rev-list --count claude/X..main`
# as a "main has moved on" indicator.
assert_branch_for_commit() {
    local force="${1:-0}"
    local branch
    branch="$(current_branch)"

    # main/master are handled by the auto-branching block in cmd_commit.
    if [ "$branch" = "main" ] || [ "$branch" = "master" ] || [ -z "$branch" ]; then
        return 0
    fi

    # Only claude/* branches are checked. Custom branches (feature/…,
    # dev, …) are user-managed — the wrapper stays out of those.
    case "$branch" in
        claude/*) ;;
        *) return 0 ;;
    esac

    if [ "$force" = "1" ]; then
        echo "⚠️  '$DISPLAY': --force set, skipping stale check for '$branch'." >&2
        return 0
    fi

    local main_ref=""
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "main" >/dev/null 2>&1; then
        main_ref="main"
    elif git -C "$REPO_ROOT" rev-parse --verify --quiet "origin/main" >/dev/null 2>&1; then
        main_ref="origin/main"
    elif git -C "$REPO_ROOT" rev-parse --verify --quiet "master" >/dev/null 2>&1; then
        main_ref="master"
    elif git -C "$REPO_ROOT" rev-parse --verify --quiet "origin/master" >/dev/null 2>&1; then
        main_ref="origin/master"
    fi

    local origin_has_branch=0
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "origin/$branch" >/dev/null 2>&1; then
        origin_has_branch=1
    fi

    local is_stale=0
    local stale_reason=""

    if [ -n "$main_ref" ]; then
        # Squash-merge detection via patch-id: `git cherry <main> <branch>`
        # lists commits from <branch> that are NOT yet in <main> (with
        # '+ <sha>'); the remaining lines are '- <sha>' = already in
        # main via patch-id equivalence (so squash merges are detected).
        local unmerged_count
        unmerged_count="$(git -C "$REPO_ROOT" cherry "$main_ref" "$branch" 2>/dev/null | grep -c '^+' || true)"

        # Has main moved past the branch?
        local ahead_main
        ahead_main="$(git -C "$REPO_ROOT" rev-list --count "$branch..$main_ref" 2>/dev/null || echo 0)"

        if [ "${unmerged_count:-0}" = "0" ] && [ "${ahead_main:-0}" -gt 0 ]; then
            is_stale=1
            if [ "$origin_has_branch" -eq 0 ]; then
                stale_reason="origin/$branch no longer exists AND every commit of '$branch' is already in '$main_ref' (likely deleted after a squash merge)"
            else
                stale_reason="'$main_ref' already contains every patch from '$branch' (likely squash-merged)"
            fi
        elif [ "$origin_has_branch" -eq 0 ] && [ "${ahead_main:-0}" -gt 0 ] && [ "${unmerged_count:-0}" -gt 0 ]; then
            # Local-only branch with its own commits, but main has moved
            # on. No clear squash signal, but not obviously active either.
            # Heuristic unclear → abort with a hint.
            is_stale=1
            stale_reason="origin/$branch does not exist (never pushed?) AND '$main_ref' has moved on — unclear whether still active"
        fi
    fi

    if [ "$is_stale" -eq 1 ]; then
        {
            echo "❌ '$DISPLAY': current branch '$branch' looks STALE — commit aborted."
            echo ""
            echo "   Indicator: $stale_reason."
            echo ""
            echo "   You probably want to branch fresh first:"
            echo "      ./claude-git.sh branch main"
            echo "      ./claude-git.sh commit \"<conventional-msg>\"   # creates a new claude/<slug>"
            echo ""
            echo "   If you really want to commit on '$branch':"
            echo "      ./claude-git.sh commit --force \"<conventional-msg>\""
        } >&2
        return 1
    fi

    return 0
}


count_unstaged() {
    git -C "$REPO_ROOT" diff --name-only 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' '
}

count_staged() {
    git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' '
}

count_untracked() {
    git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' '
}

count_unpushed() {
    # Number of commits that are local but not in the upstream.
    local branch upstream count
    branch="$(current_branch)"
    [ -z "$branch" ] && { echo "0"; return; }
    upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)"
    if [ -z "$upstream" ]; then
        # No upstream → all local commits count as unpushed.
        count="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
        echo "$count*"
    else
        count="$(git -C "$REPO_ROOT" rev-list --count "$upstream"..HEAD 2>/dev/null || echo 0)"
        echo "$count"
    fi
}

print_help() {
    cat <<EOF
claude-git.sh — per-repo git wrapper for '$DISPLAY'

USAGE:
   ./claude-git.sh <command> [args...]

COMMANDS:
   status [--porcelain]            Branch + dirty state + unpushed commits.
                                   --porcelain emits tab-separated values
                                   for the orchestrator layers.
   pull                            git pull --rebase on the current branch.
   branch [--auto-stash] <name>    Switch/create branch <name>.
                                   Aborts when a dirty working tree would
                                   be clobbered. --auto-stash = stash + switch + pop.
   commit [--force] "<message>"    Conventional Commit. Auto-branches to
                                   claude/<slug> when currently on main or master.
                                   Aborts if the current branch is stale
                                   (claude/<X> already merged into main, or
                                   deleted on origin). --force overrides.
   push                            git push -u origin <current-branch>.
   merge <branch>                  Switches to main and runs 'git merge --squash <branch>'.
                                   Sascha commits and pushes manually.
   cleanup                         Removes stale .git/*.lock files and reports
                                   what was removed. Runs automatically before
                                   every other operation as well.
   help                            This help text.

LOCK CLEANUP:
   Before every git operation the wrapper removes stale .git/*.lock
   files (index.lock, HEAD.lock, refs/**/.lock, maintenance.lock,
   *.stale-*). This is necessary because the Cowork sandbox cannot
   delete those files itself on the virtiofs mount, and follow-up
   Mac-side git operations would otherwise hang silently.

CONVENTIONAL COMMITS:
   <type>(<scope>)?!?: <description>
   Allowed types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert

BRANCH WORKFLOW:
   Claude never commits directly to main/master. Instead, the wrapper
   automatically creates a branch claude/<slug> (slug derived from the
   description, e.g. 'docs: rewrite arc42 in prose style'
   → 'claude/rewrite-arc42-in-prose-style').

BRANCH-DRIFT GUARDS:
   1. branch <name>: before the switch, the wrapper checks whether the
      switch would lose local changes (modified vs. switch-changed,
      untracked vs. target-tracked). On conflict it aborts with a clear
      error. With --auto-stash the wrapper does stash/switch/pop.
   2. commit "<msg>": before the commit, the wrapper checks the current
      branch. If it is a claude/<X> branch and either origin no longer
      has it or main has moved past it (squash-merge indicator), the
      commit is aborted with the hint "branch fresh first". --force
      overrides the check.
   Both guards prevent the branch drift where a failed git checkout
   main was treated as a mere hint and follow-up commits silently
   landed on an old claude/<X> branch.

REPO MODEL:
   Every repo (idp, platform, gateway, …) is its own git repo. This
   script operates only on '$REPO_ROOT/.git'. For operations that span
   multiple repos in the same project see '../claude-git.sh', and for
   all projects '../../claude-git.sh'.
EOF
}

# ──────────────────────────────────────────────────────────────────────
# Commands
# ──────────────────────────────────────────────────────────────────────

cmd_status() {
    local porcelain=0
    if [ "${1:-}" = "--porcelain" ]; then
        porcelain=1
    fi

    # Status only reads, but git internally sometimes uses index.lock
    # (e.g. to refresh the stat cache). Clean up just in case.
    cleanup_stale_locks "$REPO_ROOT"

    if ! is_git_repo; then
        if [ $porcelain -eq 1 ]; then
            printf 'NO-GIT\t-\t-\t-\n'
        else
            echo "$DISPLAY: not a git repo (no .git)."
        fi
        return 0
    fi

    local branch unstaged staged untracked unpushed
    branch="$(current_branch)"
    unstaged="$(count_unstaged)"
    staged="$(count_staged)"
    untracked="$(count_untracked)"
    unpushed="$(count_unpushed)"

    if [ $porcelain -eq 1 ]; then
        # branch \t unstaged(+untracked) \t staged \t unpushed
        local dirty="$unstaged"
        if [ "$untracked" != "0" ]; then
            dirty="${unstaged}+${untracked}"
        fi
        printf '%s\t%s\t%s\t%s\n' "$branch" "$dirty" "$staged" "$unpushed"
    else
        echo "Repo:      $DISPLAY"
        echo "Branch:    $branch"
        echo "Unstaged:  $unstaged file(s) modified"
        echo "Untracked: $untracked file(s) new"
        echo "Staged:    $staged file(s) ready"
        echo "Unpushed:  $unpushed commit(s) (* = no upstream set)"
    fi
}

cmd_pull() {
    require_git_repo
    cleanup_stale_locks "$REPO_ROOT"
    local branch
    branch="$(current_branch)"
    if [ -z "$branch" ]; then
        echo "❌ '$DISPLAY': no current branch found." >&2
        return 1
    fi
    echo "Pulling '$branch' in '$DISPLAY' (rebase) …"
    if ! git -C "$REPO_ROOT" pull --rebase; then
        echo "❌ '$DISPLAY': pull failed." >&2
        return 1
    fi
}

cmd_branch() {
    require_git_repo
    cleanup_stale_locks "$REPO_ROOT"

    local auto_stash=0
    local name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --auto-stash) auto_stash=1; shift ;;
            --) shift; name="${1:-}"; shift || true; break ;;
            -*) echo "Error: unknown flag '$1'." >&2; return 2 ;;
            *)  name="$1"; shift ;;
        esac
    done

    if [ -z "$name" ]; then
        echo "Error: branch requires a name." >&2
        return 2
    fi

    # Working-tree guard: would the switch lose local changes?
    if ! check_clean_worktree_for_switch "$name"; then
        if [ "$auto_stash" -eq 1 ]; then
            echo "ℹ️  '$DISPLAY': --auto-stash set — stash + switch + pop." >&2
            local stash_msg
            stash_msg="auto-stash-before-branch-$(date +%s)"
            if ! git -C "$REPO_ROOT" stash push --include-untracked -m "$stash_msg" >/dev/null; then
                echo "❌ '$DISPLAY': auto-stash failed — aborting." >&2
                return 1
            fi
            local checkout_rc=0
            if git -C "$REPO_ROOT" rev-parse --verify --quiet "$name" >/dev/null 2>&1; then
                git -C "$REPO_ROOT" checkout "$name" || checkout_rc=$?
            else
                git -C "$REPO_ROOT" checkout -b "$name" || checkout_rc=$?
            fi
            if [ "$checkout_rc" -ne 0 ]; then
                echo "❌ '$DISPLAY': switch failed, the stash is still in place — restore manually with 'git stash pop'." >&2
                return 1
            fi
            if ! git -C "$REPO_ROOT" stash pop >/dev/null; then
                echo "⚠️  '$DISPLAY': stash pop produced conflicts — resolve manually." >&2
                # Conflict during pop is user-handleable, the switch already worked.
                return 1
            fi
            echo "✓ '$DISPLAY': switched to '$name', auto-stash restored."
            return 0
        fi
        # Default: no --auto-stash → abort. check_clean_… already
        # printed the error message.
        return 1
    fi

    if git -C "$REPO_ROOT" rev-parse --verify --quiet "$name" >/dev/null 2>&1; then
        echo "↪︎  '$DISPLAY': switching to existing branch '$name'."
        if ! git -C "$REPO_ROOT" checkout "$name"; then
            echo "❌ '$DISPLAY': switch to '$name' failed — aborting." >&2
            return 1
        fi
    else
        echo "↪︎  '$DISPLAY': creating new branch '$name'."
        if ! git -C "$REPO_ROOT" checkout -b "$name"; then
            echo "❌ '$DISPLAY': creating '$name' failed — aborting." >&2
            return 1
        fi
    fi
}

cmd_commit() {
    require_git_repo
    cleanup_stale_locks "$REPO_ROOT"

    local force=0
    local msg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --force|-f) force=1; shift ;;
            --) shift; msg="${1:-}"; shift || true; break ;;
            -*) echo "Error: unknown flag '$1'." >&2; return 2 ;;
            *)  msg="$1"; shift ;;
        esac
    done

    if [ -z "$msg" ]; then
        echo "Error: commit requires a quoted message." >&2
        return 2
    fi

    if ! validate_conventional_commit "$msg"; then
        return 1
    fi

    # No changes? → skip politely.
    if [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
        echo "ℹ️  '$DISPLAY': no changes — skipped."
        return 0
    fi

    # Branch-drift guard: never silently commit on a stale claude/<X>
    # branch. assert_branch_for_commit prints the error itself, we just
    # bail out.
    if ! assert_branch_for_commit "$force"; then
        return 1
    fi

    local branch
    branch="$(current_branch)"

    # Auto-branch on main/master — only when commits already exist.
    # On the very first commit (empty repo) commit straight onto main
    # so the default branch comes into existence at all.
    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
            local first_line desc slug target
            first_line="$(printf '%s\n' "$msg" | head -n1)"
            desc="$(extract_description "$first_line")"
            slug="$(slug_from_description "$desc")"
            if [ -z "$slug" ]; then
                slug="auto-$(date +%s)"
            fi
            target="claude/$slug"

            if git -C "$REPO_ROOT" rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
                echo "↪︎  '$DISPLAY': '$branch' is protected — switching to existing '$target'."
                if ! git -C "$REPO_ROOT" checkout "$target"; then
                    echo "❌ '$DISPLAY': switch to '$target' failed — commit aborted." >&2
                    return 1
                fi
            else
                echo "↪︎  '$DISPLAY': '$branch' is protected — creating and switching to '$target'."
                if ! git -C "$REPO_ROOT" checkout -b "$target"; then
                    echo "❌ '$DISPLAY': creating '$target' failed — commit aborted." >&2
                    return 1
                fi
            fi
        else
            echo "ℹ️  '$DISPLAY': first commit — committing directly on '$branch' (no auto-branching)."
        fi
    fi

    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" commit -m "$msg"
    echo "✓ '$DISPLAY': committed on '$(current_branch)'."
}

cmd_push() {
    require_git_repo
    cleanup_stale_locks "$REPO_ROOT"
    local branch
    branch="$(current_branch)"
    if [ -z "$branch" ]; then
        echo "❌ '$DISPLAY': no current branch." >&2
        return 1
    fi

    # Does the branch have an upstream? If not → set one with -u.
    if git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
        echo "Pushing '$branch' in '$DISPLAY' …"
        git -C "$REPO_ROOT" push
    else
        echo "Pushing '$branch' in '$DISPLAY' (with -u, new branch) …"
        git -C "$REPO_ROOT" push -u origin "$branch"
    fi
}

cmd_merge() {
    require_git_repo
    cleanup_stale_locks "$REPO_ROOT"
    local source="${1:-}"
    if [ -z "$source" ]; then
        echo "Error: merge requires a source branch name." >&2
        return 2
    fi

    if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$source" >/dev/null 2>&1; then
        echo "❌ '$DISPLAY': branch '$source' does not exist." >&2
        return 1
    fi

    local target="main"
    if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
        if git -C "$REPO_ROOT" rev-parse --verify --quiet "master" >/dev/null 2>&1; then
            target="master"
        else
            echo "❌ '$DISPLAY': neither 'main' nor 'master' found." >&2
            return 1
        fi
    fi

    echo "↪︎  '$DISPLAY': switching to '$target'."
    git -C "$REPO_ROOT" checkout "$target"

    echo "↪︎  '$DISPLAY': squash-merging '$source' into '$target' (staged, not committed)."
    git -C "$REPO_ROOT" merge --squash "$source"

    cat <<EOF

ℹ️  The squash merge is staged. Sascha commits and pushes manually:

   cd "$REPO_ROOT"
   git status                          # inspect what was staged
   git commit -m "<conventional-msg>"  # Conventional Commit for the release
   git push

EOF
}

cmd_cleanup() {
    cleanup_stale_locks_verbose "$REPO_ROOT"
}

# ──────────────────────────────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        status)         cmd_status "$@" ;;
        pull)           cmd_pull "$@" ;;
        branch)         cmd_branch "$@" ;;
        commit)         cmd_commit "$@" ;;
        push)           cmd_push "$@" ;;
        merge)          cmd_merge "$@" ;;
        cleanup)        cmd_cleanup "$@" ;;
        help|-h|--help) print_help ;;
        *)
            echo "Unknown command: '$cmd'" >&2
            echo "" >&2
            print_help >&2
            return 2
            ;;
    esac
}

main "$@"
