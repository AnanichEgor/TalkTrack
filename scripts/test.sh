#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/TalkTrackKit "$@"
