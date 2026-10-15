#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_path="$PWD/.build/xcode/Build/Products/Debug/TalkTrack.app"
codesign --verify --strict "$app_path"
open "$app_path"
