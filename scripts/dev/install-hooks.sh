#!/usr/bin/env bash
# scripts/dev/install-hooks.sh
#
# Install the project pre-commit hook into the local .git/hooks directory.
# Idempotent — safe to re-run after pulling new hook updates.
#
# The hook source-of-truth lives at scripts/git-hooks/pre-commit (tracked).
# We copy rather than symlink because git hooks must be regular files +
# executable, and a broken symlink (e.g. after `rm scripts/git-hooks/`)
# would silently disable enforcement.
#
# Usage:
#   ./scripts/dev/install-hooks.sh
#
# Optional environment:
#   GIT_HOOKS_DIR  override .git/hooks location (e.g. for git worktrees)
#
# What gets installed:
#   pre-commit  — five-check gate (anonymisation / Wave 1 stale-content /
#                 credential leak / kubeconform CRD-aware / hallucination
#                 defense). See CONTRIBUTING.md for the full breakdown.
#
# After install, the hook fires on every `git commit` from this clone.
# To bypass for a specific commit (emergency only): `git commit --no-verify`.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "error: not inside a git repository" >&2
  exit 1
fi

HOOKS_DIR="${GIT_HOOKS_DIR:-$REPO_ROOT/.git/hooks}"
SOURCE_HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"
TARGET_HOOK="$HOOKS_DIR/pre-commit"

if [ ! -f "$SOURCE_HOOK" ]; then
  echo "error: source hook not found: $SOURCE_HOOK" >&2
  echo "  Are you running this from the wrong checkout?" >&2
  exit 1
fi

mkdir -p "$HOOKS_DIR"
cp "$SOURCE_HOOK" "$TARGET_HOOK"
chmod +x "$TARGET_HOOK"

echo "✓ pre-commit hook installed: $TARGET_HOOK"
echo
echo "Verify by running once against current tree:"
echo "  bash $TARGET_HOOK"
echo
echo "The hook will fire automatically on every 'git commit'."
echo "Emergency bypass (operator accepts the risk): git commit --no-verify"
