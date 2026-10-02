#!/usr/bin/env bash
# Writes build/release/appcast.xml for the zip that release.sh produced and
# signs it with the Sparkle EdDSA private key.
#
# The key comes from SPARKLE_PRIVATE_KEY (CI) or, if unset, from the login
# keychain where Sparkle's generate_keys stored it (local releases).
#
# The appcast is uploaded as a release asset, so SUFeedURL
# (releases/latest/download/appcast.xml) always points at the newest release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
BIN="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
REPO="${GITHUB_REPOSITORY:-petemcpherson/MFPete}"
VERSION="$(cat "$BUILD/VERSION")"

FEED="$BUILD/appcast"
rm -rf "$FEED"
mkdir -p "$FEED"
cp "$BUILD/MFPete-$VERSION.zip" "$FEED/"

ARGS=(
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/"
  --link "https://github.com/$REPO"
  --maximum-deltas 0
  -o "$BUILD/appcast.xml"
)

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "$SPARKLE_PRIVATE_KEY" | "$BIN/generate_appcast" --ed-key-file - "${ARGS[@]}" "$FEED"
else
  "$BIN/generate_appcast" "${ARGS[@]}" "$FEED"
fi

rm -rf "$FEED"
echo "==> Wrote $BUILD/appcast.xml"
