#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export GLITTER_REVIEW_OUTPUT="${GLITTER_REVIEW_OUTPUT:-$PWD/build/review}"
mkdir -p "$GLITTER_REVIEW_OUTPUT"

TEST_RUNNER_GLITTER_REVIEW_OUTPUT="$GLITTER_REVIEW_OUTPUT" \
  xcodebuild test \
  -project Glitter.xcodeproj \
  -scheme Glitter \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/.build/DerivedData"
