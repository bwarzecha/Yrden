#!/bin/bash
# Usage: ./scripts/setup.sh
# Clones justhtml at a pinned commit, creates a venv with pytest.
# Prints the temp dir path to stdout.
set -euo pipefail

REPO="https://github.com/EmilStenstrom/justhtml.git"
COMMIT="c330ff1"
TMPDIR=$(mktemp -d /tmp/justhtml-bugbash-XXXXXXXX)

# justhtml requires Python >=3.10; find a suitable interpreter
PYTHON=""
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" &>/dev/null; then
        ver=$("$candidate" -c 'import sys; print(sys.version_info[:2] >= (3,10))')
        if [ "$ver" = "True" ]; then
            PYTHON="$candidate"
            break
        fi
    fi
done
if [ -z "$PYTHON" ]; then
    echo "Error: Python >=3.10 required but not found" >&2
    exit 1
fi

git clone --quiet "$REPO" "$TMPDIR"
cd "$TMPDIR"
git checkout --quiet "$COMMIT"

"$PYTHON" -m venv .venv
.venv/bin/pip install --quiet --upgrade pip 2>/dev/null
.venv/bin/pip install --quiet -e . 2>/dev/null
.venv/bin/pip install --quiet pytest 2>/dev/null

echo "$TMPDIR"
