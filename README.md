# overeng-beads-public

Public beads issue tracking and reusable devenv module for commit correlation.

## Issues

This repo tracks issues for overengineering projects using [beads](https://github.com/steveyegge/beads), synced with Linear (EU team).

```bash
# List issues
bd list

# Sync with Linear
bd linear sync
```

## Devenv Module

This repo provides a reusable devenv module for commit correlation. Code repos can import it to automatically add comments to beads issues when commits reference them.

### Setup

1. Add this repo as a flake input in `devenv.yaml`:

```yaml
inputs:
  overeng-beads-public:
    url: github:overengineeringstudio/overeng-beads-public
    flake: true
```

2. Import the module in `devenv.nix`:

```nix
{ inputs, ... }: {
  imports = [
    (inputs.overeng-beads-public.devenvModules.beads {
      beadsPrefix = "eu";           # Issue prefix (e.g. eu-abc123)
      beadsRepoName = "overeng-beads-public";  # Beads repo name (peer in same parent dir)
    })
  ];
}
```

3. Reference issues in commit messages using parenthesized format:

```bash
git commit -m "Add retry logic (eu-abc123)"
```

The post-commit hook will automatically add a comment to the referenced beads issue.

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `beadsPrefix` | Yes | Issue prefix (e.g. `eu`, `sch`) |
| `beadsRepoName` | Yes | Name of the beads repo, assumed to be a peer directory |

### How It Works

The module installs a git `post-commit` hook that:
1. Extracts issue references matching `(prefix-xxx)` from commit messages
2. Adds a comment to each referenced issue with the commit SHA and message
3. Derives the beads DB path as `../{beadsRepoName}/.beads/beads.db`
