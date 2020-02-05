#!/usr/bin/env bash
set -eu -o pipefail

# Convenience script for the task of updating the git commits in the
# example files.

# Update file
COMMIT="$(git rev-parse HEAD)"
perl -pi -e "s:/static-haskell-nix/archive/........................................:/static-haskell-nix/archive/${COMMIT}:g" static-stack2nix-builder-example/default.nix

# Commit
git reset
git add static-stack2nix-builder-example/default.nix
git commit -m 'Update example commits'
