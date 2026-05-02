#!/usr/bin/env bash
# claude-git.sh — Per-Vertical-Git-Wrapper.
#
# Remote: ssh://git@git.mon.k8b.co:2222/chameleon-ci/trivy.git
#
# Operiert auf dem .git-Repo dieses einen Verticals (jedes Vertical ist
# ein eigenes Git-Repo, kein Monorepo). Wird von den höheren Schichten
# (../claude-git.sh und ../../claude-git.sh) delegiert, funktioniert aber
# auch eigenständig, wenn man direkt im Vertical-Ordner steht.
#
# Conventional Commits 1.0 sind Pflicht. Auf main/master wird automatisch
# auf einen claude/<slug>-Branch gewechselt.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERTICAL_NAME="$(basename "$REPO_ROOT")"
PROJECT_NAME="$(basename "$(dirname "$REPO_ROOT")")"
DISPLAY="$PROJECT_NAME/$VERTICAL_NAME"

# Gültige Conventional-Commits-Types
readonly CC_TYPES='feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert'

# ──────────────────────────────────────────────────────────────────────
# Hilfsfunktionen
# ──────────────────────────────────────────────────────────────────────

# Räumt stale .git/*.lock-Files auf, die die Cowork-Sandbox auf dem
# virtiofs-Mount nicht selbst entfernen kann. Wird vor jeder Git-
# Operation aufgerufen, damit Mac-seitige Folge-Operationen nicht silent
# auf einem alten index.lock hängen bleiben. Idempotent, defensiv,
# stumm wenn nichts zu tun ist.
cleanup_stale_locks() {
    local repo_dir="$1"
    [ -d "$repo_dir/.git" ] || return 0

    # Wichtig: find -delete kann auf manchen Mounts (z.B. virtiofs in der
    # Cowork-Sandbox) fehlschlagen. Wir wollen die Wrapper-Operation
    # darüber NICHT abbrechen — daher pro find-Aufruf '|| true' und
    # stderr nach /dev/null. Auf dem Mac (wo dieser Wrapper primär läuft)
    # gehen die deletes durch und alles ist gut; in der Sandbox blockt
    # virtiofs, aber Git wird die Sandbox-Locks ignorieren, sobald der
    # Mac-Cleanup wieder gegriffen hat.

    # Standard-Locks (index, HEAD, *.stuck.*, *.stale-*)
    find "$repo_dir/.git" -maxdepth 3 \( \
           -name 'index.lock' \
        -o -name 'HEAD.lock' \
        -o -name '*.lock.stale-*' \
        -o -name '*.stale-*' \
        -o -name '*.lock.stuck.*' \
        -o -name '*.stuck.*' \
    \) -type f -delete 2>/dev/null || true

    # Maintenance-Locks im objects/-Verzeichnis
    find "$repo_dir/.git/objects" -name 'maintenance.lock' -type f -delete 2>/dev/null || true

    # Ref-Locks (Tags, Branches)
    find "$repo_dir/.git/refs" -name '*.lock' -type f -delete 2>/dev/null || true

    # Cipipe-Locks (von CI-Skripten oder Stash-Operations)
    find "$repo_dir/.git" -maxdepth 2 -name '*.tmp.*.lock' -type f -delete 2>/dev/null || true

    return 0
}

# Variante mit Reporting für den expliziten cleanup-Befehl.
cleanup_stale_locks_verbose() {
    local repo_dir="$1"
    [ -d "$repo_dir/.git" ] || { echo "ℹ️  '$DISPLAY': kein .git — nichts zu tun."; return 0; }

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

    # Nach dem Cleanup nochmal prüfen, was tatsächlich weg ist — auf dem
    # virtiofs-Mount der Cowork-Sandbox kann das Delete blocken, dann
    # listen wir die Files als „nicht entfernt" auf, statt fälschlich zu
    # behaupten, alles sei sauber.
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
        echo "✓ '$DISPLAY': keine stale Locks."
        return 0
    fi

    if [ "${#removed[@]}" -gt 0 ]; then
        echo "✓ '$DISPLAY': ${#removed[@]} stale Lock(s) entfernt:"
        for f in "${removed[@]}"; do
            echo "    .git/${f#"$repo_dir/.git/"}"
        done
    fi
    if [ "${#still_there[@]}" -gt 0 ]; then
        echo "⚠️  '$DISPLAY': ${#still_there[@]} Lock(s) konnten nicht entfernt werden (virtiofs?):"
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
❌ '$DISPLAY' ist (noch) kein Git-Repo.

Erst lokal initialisieren oder klonen:
   cd "$REPO_ROOT"
   git init                              # neues, leeres Repo
   # oder
   git clone <forgejo-url> .             # bestehendes Repo holen

Dieses Vertical wird von den Orchestrator-Skripten dann automatisch
mit aufgegriffen.
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
❌ Commit-Message verletzt Conventional Commits 1.0:
   '$first_line'

Erwartetes Format:
   <type>(<scope>)?!?: <description>

Gültige Types:
   feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert

Beispiele:
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
    # Erzeugt einen Slug aus der Commit-Beschreibung (lowercase, [a-z0-9-], max 40 Zeichen).
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
    # Holt den Beschreibungs-Teil nach dem ersten ': ' aus dem Header.
    local first_line="$1"
    printf '%s' "$first_line" | sed -E 's/^[^:]+: //'
}

current_branch() {
    git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
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
    # Anzahl Commits, die lokal sind aber nicht im Upstream.
    local branch upstream count
    branch="$(current_branch)"
    [ -z "$branch" ] && { echo "0"; return; }
    upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)"
    if [ -z "$upstream" ]; then
        # Kein Upstream → alle lokalen Commits gelten als unpushed.
        count="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
        echo "$count*"
    else
        count="$(git -C "$REPO_ROOT" rev-list --count "$upstream"..HEAD 2>/dev/null || echo 0)"
        echo "$count"
    fi
}

print_help() {
    cat <<EOF
claude-git.sh — Per-Vertical-Git-Wrapper für '$DISPLAY'

VERWENDUNG:
   ./claude-git.sh <command> [args...]

COMMANDS:
   status [--porcelain]    Branch + Dirty-State + unpushed Commits.
                           --porcelain liefert tab-separierte Werte
                           für die Orchestrator-Schichten.
   pull                    git pull --rebase auf dem aktuellen Branch.
   branch <name>           Wechselt/erstellt Branch <name>.
   commit "<message>"      Conventional-Commit. Auto-Branching auf
                           claude/<slug> wenn aktuell main oder master.
                           Validiert das Format strikt.
   push                    git push -u origin <current-branch>.
   merge <branch>          Wechselt auf main, macht 'git merge --squash <branch>'.
                           Sascha committet und pusht selbst.
   cleanup                 Räumt stale .git/*.lock-Files auf und meldet,
                           was entfernt wurde. Wird vor jeder anderen
                           Operation ohnehin automatisch ausgeführt.
   help                    Diese Hilfe.

LOCK-CLEANUP:
   Vor jeder Git-Operation räumt der Wrapper stale .git/*.lock-Files
   auf (index.lock, HEAD.lock, refs/**/.lock, maintenance.lock,
   *.stale-*). Das ist nötig, weil die Cowork-Sandbox auf dem
   virtiofs-Mount diese Files nach Abbruch nicht selbst entfernen kann
   und nachfolgende Mac-seitige Git-Operationen sonst silent hängen.

CONVENTIONAL COMMITS:
   <type>(<scope>)?!?: <description>
   Gültige Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert

BRANCH-WORKFLOW:
   Claude committet niemals direkt auf main/master. Statt dessen wird
   automatisch ein Branch claude/<slug> erstellt (Slug aus der Beschreibung,
   z.B. 'docs: rewrite arc42 in prose style' → 'claude/rewrite-arc42-in-prose-style').

VERTICAL-REPO-MODELL:
   Jedes Vertical (idp, platform, gateway, …) ist ein eigenständiges
   Git-Repo. Dieses Skript operiert ausschließlich auf '$REPO_ROOT/.git'.
   Für Operationen über mehrere Verticals des gleichen Projekts siehe
   '../claude-git.sh', über alle Projekte hinweg '../../claude-git.sh'.
EOF
}

# ──────────────────────────────────────────────────────────────────────
# Befehle
# ──────────────────────────────────────────────────────────────────────

cmd_status() {
    local porcelain=0
    if [ "${1:-}" = "--porcelain" ]; then
        porcelain=1
    fi

    # Status liest zwar nur, aber Git nutzt intern manchmal index.lock
    # (z.B. für refresh des stat-cache). Sicherheitshalber aufräumen.
    cleanup_stale_locks "$REPO_ROOT"

    if ! is_git_repo; then
        if [ $porcelain -eq 1 ]; then
            printf 'NO-GIT\t-\t-\t-\n'
        else
            echo "$DISPLAY: kein Git-Repo (kein .git)."
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
        echo "Vertical:  $DISPLAY"
        echo "Branch:    $branch"
        echo "Unstaged:  $unstaged Datei(en) geändert"
        echo "Untracked: $untracked Datei(en) neu"
        echo "Staged:    $staged Datei(en) bereit"
        echo "Unpushed:  $unpushed Commit(s) (* = kein Upstream gesetzt)"
    fi
}

cmd_pull() {
    require_git_repo
    cleanup_stale_locks "$REPO_ROOT"
    local branch
    branch="$(current_branch)"
    if [ -z "$branch" ]; then
        echo "❌ '$DISPLAY': Kein aktueller Branch gefunden." >&2
        return 1
    fi
    echo "Pulling '$branch' in '$DISPLAY' (rebase) …"
    if ! git -C "$REPO_ROOT" pull --rebase; then
        echo "❌ '$DISPLAY': Pull fehlgeschlagen." >&2
        return 1
    fi
}

cmd_branch() {
    require_git_repo
    cleanup_stale_locks "$REPO_ROOT"
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Fehler: branch benötigt einen Namen." >&2
        return 2
    fi
    if git -C "$REPO_ROOT" rev-parse --verify --quiet "$name" >/dev/null 2>&1; then
        echo "↪︎  '$DISPLAY': Wechsle auf bestehenden Branch '$name'."
        git -C "$REPO_ROOT" checkout "$name"
    else
        echo "↪︎  '$DISPLAY': Erstelle neuen Branch '$name'."
        git -C "$REPO_ROOT" checkout -b "$name"
    fi
}

cmd_commit() {
    require_git_repo
    cleanup_stale_locks "$REPO_ROOT"
    local msg="${1:-}"
    if [ -z "$msg" ]; then
        echo "Fehler: commit benötigt eine Message in Anführungszeichen." >&2
        return 2
    fi

    if ! validate_conventional_commit "$msg"; then
        return 1
    fi

    # Keine Änderungen? → freundlich überspringen.
    if [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
        echo "ℹ️  '$DISPLAY': Keine Änderungen — übersprungen."
        return 0
    fi

    local branch
    branch="$(current_branch)"

    # Auto-Branching auf main/master — nur wenn bereits Commits existieren.
    # Beim allerersten Commit (leeres Repo) direkt auf main committen,
    # damit der default-Branch überhaupt entsteht.
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
                echo "↪︎  '$DISPLAY': '$branch' ist geschützt — wechsle auf bestehenden '$target'."
                git -C "$REPO_ROOT" checkout "$target"
            else
                echo "↪︎  '$DISPLAY': '$branch' ist geschützt — erstelle und wechsle auf '$target'."
                git -C "$REPO_ROOT" checkout -b "$target"
            fi
        else
            echo "ℹ️  '$DISPLAY': Erster Commit — direkt auf '$branch' (kein Auto-Branching)."
        fi
    fi

    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" commit -m "$msg"
    echo "✓ '$DISPLAY': Commit auf '$(current_branch)' gemacht."
}

cmd_push() {
    require_git_repo
    cleanup_stale_locks "$REPO_ROOT"
    local branch
    branch="$(current_branch)"
    if [ -z "$branch" ]; then
        echo "❌ '$DISPLAY': Kein aktueller Branch." >&2
        return 1
    fi

    # Hat der Branch ein Upstream? Wenn nein → -u setzen.
    if git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
        echo "Pushing '$branch' in '$DISPLAY' …"
        git -C "$REPO_ROOT" push
    else
        echo "Pushing '$branch' in '$DISPLAY' (mit -u, neuer Branch) …"
        git -C "$REPO_ROOT" push -u origin "$branch"
    fi
}

cmd_merge() {
    require_git_repo
    cleanup_stale_locks "$REPO_ROOT"
    local source="${1:-}"
    if [ -z "$source" ]; then
        echo "Fehler: merge benötigt einen Source-Branch-Namen." >&2
        return 2
    fi

    if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$source" >/dev/null 2>&1; then
        echo "❌ '$DISPLAY': Branch '$source' existiert nicht." >&2
        return 1
    fi

    local target="main"
    if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
        if git -C "$REPO_ROOT" rev-parse --verify --quiet "master" >/dev/null 2>&1; then
            target="master"
        else
            echo "❌ '$DISPLAY': Weder 'main' noch 'master' gefunden." >&2
            return 1
        fi
    fi

    echo "↪︎  '$DISPLAY': Wechsle auf '$target'."
    git -C "$REPO_ROOT" checkout "$target"

    echo "↪︎  '$DISPLAY': Squash-Merge von '$source' nach '$target' (gestaged, nicht committed)."
    git -C "$REPO_ROOT" merge --squash "$source"

    cat <<EOF

ℹ️  Der Squash-Merge ist gestaged. Sascha committet und pusht jetzt selbst:

   cd "$REPO_ROOT"
   git status                          # prüfen, was gestaged wurde
   git commit -m "<conventional-msg>"  # Conventional Commit für Release
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
            echo "Unbekanntes Kommando: '$cmd'" >&2
            echo "" >&2
            print_help >&2
            return 2
            ;;
    esac
}

main "$@"
