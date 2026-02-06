# Beads devenv module — integrates beads issue tracking with devenv.
#
# Runs beads in daemon mode (SQLite DB + JSONL auto-sync). The daemon:
# - Serializes concurrent access via RPC (safe for multiple workspaces)
# - Auto-flushes DB changes to JSONL
# - Auto-imports when JSONL is newer (e.g. after commit-correlation hook writes)
# - Auto-commits + auto-pushes JSONL changes to git
# - Auto-pulls remote changes
#
# The SQLite DB is gitignored (.beads/.gitignore) — JSONL remains the
# git-portable source of truth. Multiple megarepo workspaces sharing the
# same store worktree share a single daemon instance.
#
# Provides:
# - BEADS_REPO / BEADS_PREFIX env vars for scripts and tasks
# - bd() shell wrapper (runs bd from the beads repo)
# - beads:daemon:ensure task — starts daemon if not running (idempotent)
# - beads:daemon:stop task — stops daemon (cleanup)
# - beads:sync task — manual full sync (fallback, rarely needed with daemon)
# - beads-commit-correlation git hook — cross-references commits with beads issues
#
# Parameters:
#   beadsPrefix    — issue ID prefix (e.g. "oep")
#   beadsRepoName  — megarepo member name (e.g. "overeng-beads-public")
#   beadsRepoPath  — path to beads repo relative to devenv root
#                    (default: "repos/${beadsRepoName}" for megarepo members)
#   enableDaemon   — enable daemon mode with auto-sync (default: true)
#                    set to false for --no-db --no-daemon mode (legacy)
{ beadsPrefix, beadsRepoName, beadsRepoPath ? "repos/${beadsRepoName}", enableDaemon ? true }: { pkgs, config, ... }:
let
  beadsRepoRelPath = beadsRepoPath;
  # Flags for the bd wrapper: daemon mode uses defaults, legacy disables daemon+db
  bdFlags = if enableDaemon then "" else "--no-daemon --no-db";
in
{
  enterShell = ''
    export BEADS_PREFIX="${beadsPrefix}"
    export BEADS_REPO="$DEVENV_ROOT/${beadsRepoRelPath}"

    # Wrapper: run bd from the beads repo directory.
    # This makes `bd list`, `bd show`, etc. work from anywhere in the devenv.
    bd() {
      if [ ! -d "$BEADS_REPO/.beads" ]; then
        echo "[beads] Beads repo not found at ${beadsRepoRelPath}. Run: dt megarepo:sync" >&2
        return 1
      fi
      (cd "$BEADS_REPO" && command bd ${bdFlags} "$@")
    }
  '';

  # beads:daemon:ensure — Start daemon if not running. Idempotent: if another
  # workspace already started a daemon for this repo, this is a no-op.
  tasks."beads:daemon:ensure" = {
    description = "Ensure beads daemon is running with auto-sync";
    after = [ "megarepo:sync" ];
    exec = if enableDaemon then ''
      BEADS_REPO="$DEVENV_ROOT/${beadsRepoRelPath}"

      if [ ! -d "$BEADS_REPO/.beads" ]; then
        echo "[beads] Beads repo not materialized, skipping daemon."
        exit 0
      fi

      cd "$BEADS_REPO"

      # If daemon already running (e.g. started by another workspace), skip
      if bd daemon status >/dev/null 2>&1; then
        echo "[beads] Daemon already running."
        exit 0
      fi

      # Start daemon in background with auto-sync
      echo "[beads] Starting daemon with auto-sync..."
      bd daemon start --auto-commit --auto-push --auto-pull 2>&1
      echo "[beads] Daemon started."
    '' else ''
      exit 0
    '';
    status = if enableDaemon then ''
      BEADS_REPO="$DEVENV_ROOT/${beadsRepoRelPath}"
      [ ! -d "$BEADS_REPO/.beads" ] && exit 0
      cd "$BEADS_REPO"
      bd daemon status >/dev/null 2>&1
    '' else "exit 0";
  };

  tasks."beads:daemon:stop" = {
    description = "Stop beads daemon";
    exec = ''
      BEADS_REPO="$DEVENV_ROOT/${beadsRepoRelPath}"
      [ ! -d "$BEADS_REPO/.beads" ] && exit 0
      cd "$BEADS_REPO"
      bd daemon stop 2>&1 || true
      echo "[beads] Daemon stopped."
    '';
  };

  # beads:sync — Manual full sync. With daemon mode, this is rarely needed
  # since the daemon auto-syncs. Useful as explicit sync or fallback.
  tasks."beads:sync" = {
    description = "Sync beads: pull + export + commit + push";
    after = [ "megarepo:sync" ];
    exec = if enableDaemon then ''
      BEADS_REPO="$DEVENV_ROOT/${beadsRepoRelPath}"

      if [ ! -d "$BEADS_REPO/.beads" ]; then
        echo "[beads] Beads repo not found at ${beadsRepoRelPath}." >&2
        exit 1
      fi

      cd "$BEADS_REPO"
      echo "[beads] Running full sync..."
      bd sync --full 2>&1
      echo "[beads] Sync complete."
    '' else ''
      BEADS_REPO="$DEVENV_ROOT/${beadsRepoRelPath}"

      if [ ! -d "$BEADS_REPO/.beads" ]; then
        echo "[beads] Beads repo not found at ${beadsRepoRelPath}." >&2
        exit 1
      fi

      cd "$BEADS_REPO"

      # Pull remote changes first
      echo "[beads] Pulling remote changes..."
      git pull --rebase 2>&1 || true

      # Check if there are local changes to commit
      if git diff --quiet .beads/ 2>/dev/null && git diff --cached --quiet .beads/ 2>/dev/null; then
        echo "[beads] No changes to push."
        exit 0
      fi

      # Commit and push
      echo "[beads] Committing changes..."
      git add .beads/
      git commit -m "beads: sync issues" 2>&1

      echo "[beads] Pushing..."
      git push 2>&1

      echo "[beads] Sync complete."
    '';
  };

  git-hooks.hooks.beads-commit-correlation = {
    enable = true;
    # Always use --no-daemon --no-db for the hook: it runs in git hook context
    # where the daemon may not be reachable. Writing directly to JSONL is fast
    # and reliable. The daemon auto-imports JSONL changes on its next poll.
    entry = "${pkgs.writeShellScript "beads-post-commit" ''
      set -euo pipefail

      GIT_ROOT="$(git rev-parse --show-toplevel)"
      BEADS_REPO="''${GIT_ROOT}/${beadsRepoRelPath}"
      BEADS_PREFIX="${beadsPrefix}"

      # Skip if beads repo doesn't exist
      [ ! -d "$BEADS_REPO/.beads" ] && exit 0

      # Get commit info
      COMMIT_SHORT=$(git rev-parse --short HEAD)
      COMMIT_MSG=$(git log -1 --format=%B)
      REPO_NAME=$(basename "$GIT_ROOT")

      # Extract issue references matching (prefix-xxx) pattern
      ISSUES=$(echo "$COMMIT_MSG" | grep -oE "\(''${BEADS_PREFIX}-[a-z0-9]+\)" | tr -d '()' || true)

      [ -z "$ISSUES" ] && exit 0

      # Add comment to each referenced issue (uses --no-db mode for reliability)
      for issue_id in $ISSUES; do
        comment="Commit ''${COMMIT_SHORT} in ''${REPO_NAME}: ''${COMMIT_MSG%%$'\n'*}"
        (cd "$BEADS_REPO" && command bd --no-daemon --no-db comment "$issue_id" "$comment") 2>/dev/null || true
      done
    ''}";
    stages = ["post-commit"];
    always_run = true;
    pass_filenames = false;
  };
}
