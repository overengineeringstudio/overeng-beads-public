{ beadsPrefix, beadsRepoName }: { pkgs, ... }: {
  git-hooks.hooks.beads-commit-correlation = {
    enable = true;
    entry = "${pkgs.writeShellScript "beads-post-commit" ''
      set -euo pipefail

      # Derive DB path from git root and beads repo name (assumes peer repos in same parent dir)
      BEADS_DB="$(git rev-parse --show-toplevel)/../${beadsRepoName}/.beads/beads.db"
      BEADS_PREFIX="${beadsPrefix}"

      # Skip if DB doesn't exist
      [ ! -f "$BEADS_DB" ] && exit 0

      # Get commit info
      COMMIT_SHORT=$(git rev-parse --short HEAD)
      COMMIT_MSG=$(git log -1 --format=%B)
      REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")

      # Extract issue references matching (prefix-xxx) pattern
      ISSUES=$(echo "$COMMIT_MSG" | grep -oE "\(''${BEADS_PREFIX}-[a-z0-9]+\)" | tr -d '()' || true)

      [ -z "$ISSUES" ] && exit 0

      # Add comment to each referenced issue
      for issue_id in $ISSUES; do
        comment="Commit ''${COMMIT_SHORT} in ''${REPO_NAME}: ''${COMMIT_MSG%%$'\n'*}"
        bd --no-daemon --db "$BEADS_DB" comment "$issue_id" "$comment" 2>/dev/null || true
      done
    ''}";
    stages = ["post-commit"];
    always_run = true;
    pass_filenames = false;
  };
}
