#!/bin/bash
# Builds a Release TalkTrack.app for Apple Silicon and packages it as a DMG
# that other people can download and install.
#
#   ./scripts/package.sh
#       Ad-hoc signed. Runs on any Apple Silicon Mac with macOS 15+, but the
#       first launch must be allowed in System Settings ▸ Privacy & Security.
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" TEAM_ID=TEAMID \
#   NOTARY_PROFILE=<notarytool keychain profile> ./scripts/package.sh
#       Developer ID signed, notarized and stapled: opens without warnings.
#       Requires a paid Apple Developer Program membership.
#
# Output: .build/dist/TalkTrack.dmg and its .sha256 file, to attach to a GitHub
# release. The name has no version, so the README link
# .../releases/latest/download/TalkTrack.dmg always gets the newest release.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n "s/^ *CFBundleShortVersionString: '\(.*\)'$/\1/p" project.yml)
[[ -n "$version" ]] || { echo "Cannot read CFBundleShortVersionString from project.yml" >&2; exit 1; }
derived=.build/xcode-release
dist=.build/dist
staging=.build/dmg-staging
app="$derived/Build/Products/Release/TalkTrack.app"
dmg="$dist/TalkTrack.dmg"

identity=${SIGN_IDENTITY:--}
if [[ "$identity" == "-" ]]; then
    # Hardened runtime is only needed for notarization; an ad-hoc signature
    # cannot be notarized, so it is left off.
    signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO)
else
    [[ -n "${TEAM_ID:-}" ]] || { echo "Set TEAM_ID together with SIGN_IDENTITY" >&2; exit 1; }
    signing=(CODE_SIGN_IDENTITY="$identity" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID"
             ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

xcodegen generate --spec project.yml
xcodebuild -project TalkTrack.xcodeproj -scheme TalkTrack -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  -clonedSourcePackagesDirPath .build/dependencies \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO "${signing[@]}" clean build
codesign --verify --strict --deep --verbose=2 "$app"

rm -rf "$staging" "$dmg" "$dmg.sha256"
mkdir -p "$staging" "$dist"
ditto "$app" "$staging/TalkTrack.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "TalkTrack $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" 2>&1 | grep -v deprecated || true
[[ -f "$dmg" ]] || { echo "DMG was not created" >&2; exit 1; }
rm -rf "$staging"

if [[ "$identity" != "-" ]]; then
    codesign --sign "$identity" --timestamp "$dmg"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$dmg"
        spctl --assess --type open --context context:primary-signature --verbose "$dmg"
    fi
fi

(cd "$dist" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
echo "Packaged $dmg"
cat "$dmg.sha256"
