#!/bin/zsh
# Builds a Release copy of iFileList and packages it as build/iFileList-<version>.dmg.
#
# Optional environment:
#   SIGN_IDENTITY   Developer ID Application identity to sign with, e.g.
#                   "Developer ID Application: Name (TEAMID)". Without it the app is ad-hoc signed.
#   NOTARY_PROFILE  notarytool keychain profile (see `xcrun notarytool store-credentials`).
#                   Requires SIGN_IDENTITY. The DMG is notarized and stapled.

set -euo pipefail

cd "${0:A:h}/.."

derived=build
app="$derived/Build/Products/Release/iFileList.app"
staging="$derived/dmg-staging"

xcodebuild -project iFileList.xcodeproj -scheme iFileList -configuration Release \
    -derivedDataPath "$derived" ONLY_ACTIVE_ARCH=NO clean build

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
fi
codesign --verify --strict "$app"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg="$derived/iFileList-$version.dmg"

rm -rf "$staging"
mkdir -p "$staging"
ditto "$app" "$staging/iFileList.app"
ln -s /Applications "$staging/Applications"

hdiutil create -volname "iFileList" -srcfolder "$staging" -fs HFS+ -format ULFO -ov "$dmg"
rm -rf "$staging"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "NOTARY_PROFILE requires SIGN_IDENTITY" >&2; exit 1; }
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
fi

echo "Created $dmg"
