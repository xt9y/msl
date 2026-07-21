#!/bin/bash
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 \"commit message\" version"
    echo "  e.g. $0 \"v1.5.5: deep dive cleanup\" 1.5.5"
    exit 1
fi

MSG="$1"
VER="$2"

# Sanity: version should be something like 1.5.5
if ! echo "$VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "error: version must be in the form MAJOR.MINOR.PATCH (got: $VER)"
    exit 1
fi

echo "=== Releasing v$VER ==="
echo "Message: $MSG"
echo ""

# Commit first so the tree is clean, then tag, then build.
# The Makefile reads the version from `git describe --tags`, so
# the tag must exist before building for the version to be correct.
echo "--- git add -A ---"
git add -A

echo "--- git commit ---"
git commit -m "$MSG"

echo "--- git tag -f v$VER ---"
git tag -f "v$VER"

# Build to verify the new version compiles
echo "--- make clean && make ---"
make clean
make

echo "--- Verifying binary reports v$VER ---"
BUILT_VER=$(./build/msl version 2>&1 | awk '{print $2}')
if [ "$BUILT_VER" != "$VER" ]; then
    echo "error: version mismatch — built reports '$BUILT_VER', expected '$VER'"
    exit 1
fi
echo "Binary OK (v$BUILT_VER)"

echo "--- git push ---"
git push --tags

# Download tarball and compute sha256
echo "--- Downloading tarball ---"
TARBALL_URL="https://github.com/xt9y/msl/archive/refs/tags/v$VER.tar.gz"
SHA=$(curl -sL "$TARBALL_URL" | shasum -a 256 | awk '{print $1}')
echo "sha256: $SHA"

# Update homebrew tap
TAP_DIR="/tmp/homebrew-msl"
if [ -d "$TAP_DIR" ]; then
    echo "--- Pulling existing tap ---"
    cd "$TAP_DIR" && git pull
else
    echo "--- Cloning tap ---"
    git clone https://github.com/xt9y/homebrew-msl.git "$TAP_DIR"
fi

echo "--- Updating formulae ---"
sed -i '' "s|url \".*\"|url \"$TARBALL_URL\"|" "$TAP_DIR/Formula/msl.rb" "$TAP_DIR/Formula/msld.rb"
sed -i '' "s|sha256 \".*\"|sha256 \"$SHA\"|" "$TAP_DIR/Formula/msl.rb" "$TAP_DIR/Formula/msld.rb"

echo "--- Committing and pushing tap ---"
cd "$TAP_DIR"
git add Formula/msl.rb Formula/msld.rb
git commit -m "$MSG"
git push

echo ""
echo "Done: v$VER published to homebrew."
