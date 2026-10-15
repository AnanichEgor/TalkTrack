#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f project.devtools.yml ]]; then export TALKTRACK_DEVTOOLS=true; fi
xcodegen generate --spec project.yml
xcodebuild -resolvePackageDependencies -project TalkTrack.xcodeproj \
  -scheme TalkTrack -clonedSourcePackagesDirPath .build/dependencies
