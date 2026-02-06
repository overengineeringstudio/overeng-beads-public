# Beads devenv module — integrates beads issue tracking with devenv.
#
# Uses --no-db mode (JSONL as source of truth) which works cleanly with
# megarepo's bare+worktree git layout. No SQLite DB needed.
#
# Provides:
# - BEADS_REPO / BEADS_PREFIX env vars for scripts and tasks
# - bd() shell wrapper (runs bd in --no-db mode from the beads repo)
# - beads:sync task — git pull, then commit + push JSONL changes
# - beads-commit-correlation git hook — cross-references commits with beads issues
#
# Parameters:
#   beadsPrefix    — issue ID prefix (e.g. "oep")
#   beadsRepoName  — megarepo member name (e.g. "overeng-beads-public")
#   beadsRepoPath  — path to beads repo relative to devenv root
#                    (default: "repos/${beadsRepoName}" for megarepo members)
{ beadsPrefix, beadsRepoName, beadsRepoPath ? "repos/${beadsRepoName}" }: { pkgs, config, ... }:
{
  enterShell = ''
    export BEADS_PREFIX="${beadsPrefix}"
    export BEADS_REPO="$DEVENV_ROOT/${beadsRepoPath}"

    # Wrapper: run bd in --no-db mode from the beads repo directory.
    # This makes `bd list`, `bd show`, etc. work from anywhere in the devenv.
    bd() {
      if [ ! -d "$BEADS_REPO/.beads" ]; then
        echo "[beads] Beads repo not found at ${beadsRepoPath}. Run: dt megarepo:sync" >&2
        return 1
      fi
      (cd "$BEADS_REPO" && command bd --no-daemon --no-db "$@")
    }
  '';

  # beads:sync — Pull remote changes, then commit + push local JSONL changes.
  # Works from the megarepo store worktree which has a .git file.
  tasks."beads:sync" = {
    description = "Sync beads: git pull, commit + push JSONL changes";
    after = [ "megarepo:sync" ];
    exec = ''
      BEADS_REPO="$DEVENV_ROOT/${beadsRepoPath}"

      if [ ! -d "$BEADS_REPO/.beads" ]; then
        echo "[beads] Beads repo not found at ${beadsRepoPath}." >&2
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
    entry = "${pkgs.writeShellScript "beads-post-commit" ''
      set -euo pipefail

      GIT_ROOT="$(git rev-parse --show-toplevel)"
      BEADS_REPO="''${GIT_ROOT}/${beadsRepoPath}"
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

      # Add comment to each referenced issue (uses --no-db mode)
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
