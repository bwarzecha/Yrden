#!/bin/bash
# Usage: ./scripts/setup.sh [repo_path]
# Creates a temp dir with a clean checkout of the pinned commit.
# Prints the temp dir path to stdout.
set -euo pipefail

REPO="${1:-$(git rev-parse --show-toplevel)}"
COMMIT="677def9"
TMPDIR=$(mktemp -d /tmp/yrden-bugbash-XXXXXXXX)

git clone --quiet --no-checkout "$REPO" "$TMPDIR"
cd "$TMPDIR"
git checkout --quiet "$COMMIT"

echo "$TMPDIR"
