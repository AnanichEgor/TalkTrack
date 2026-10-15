#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Local developer tools (debug screens, model fixtures) are included when present.
if [[ -f project.devtools.yml ]]; then export TALKTRACK_DEVTOOLS=true; fi
xcodegen generate --spec project.yml
xcodebuild -project TalkTrack.xcodeproj -scheme TalkTrack -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -clonedSourcePackagesDirPath .build/dependencies \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates "$@" build
codesign --verify --strict --verbose=2 .build/xcode/Build/Products/Debug/TalkTrack.app
