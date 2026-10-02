#!/usr/bin/env bash
# Builds a signed, notarized, stapled MFPete release.
#
# Output in build/release/:
#   MFPete-<version>.dmg   manual download
#   MFPete-<version>.zip   Sparkle update archive
#
# Requirements:
#   - A "Developer ID Application" certificate in the keychain.
#   - Notarization credentials, either:
#       NOTARY_PROFILE  a keychain profile made with
#                       `xcrun notarytool store-credentials`, or
#       NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER  an App Store Connect API key.
#   - SKIP_NOTARIZE=1 skips notarization and stapling (local test builds only).
#
# Optional:
#   MARKETING_VERSION  version string, for example 1.0.0 (default: project setting)
#   BUILD_NUMBER       CFBundleVersion (default: git commit count, so it always
#                      goes up; Sparkle compares this number)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/MFPete.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/MFPete.app"
PACKAGES="$ROOT/build/SourcePackages"
TEAM_ID="${TEAM_ID:-A2T9Q78M27}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> Archiving"
xcodebuild archive \
  -project "$ROOT/MFPete.xcodeproj" \
  -scheme MFPete \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  ${MARKETING_VERSION:+MARKETING_VERSION="$MARKETING_VERSION"} \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "==> MFPete $VERSION"

codesign --verify --deep --strict --verbose=2 "$APP"

notarize() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" \
      --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  fi
}

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo "==> Notarizing app"
  ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
  notarize "$BUILD/notarize.zip"
  rm "$BUILD/notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

echo "==> Packaging zip (Sparkle)"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD/MFPete-$VERSION.zip"

echo "==> Packaging dmg"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MFPete" -srcfolder "$STAGE" -ov -format UDZO "$BUILD/MFPete-$VERSION.dmg"
rm -rf "$STAGE"
codesign --sign "Developer ID Application" --timestamp "$BUILD/MFPete-$VERSION.dmg"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo "==> Notarizing dmg"
  notarize "$BUILD/MFPete-$VERSION.dmg"
  xcrun stapler staple "$BUILD/MFPete-$VERSION.dmg"
fi

echo "$VERSION" > "$BUILD/VERSION"
echo "==> Done: $BUILD"
