#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d /private/tmp/glitter-check.XXXXXX)
trap 'rm -rf "$CHECK_DIR"' EXIT
export GLITTER_REVIEW_OUTPUT="${GLITTER_REVIEW_OUTPUT:-$PWD/build/review}"
mkdir -p "$GLITTER_REVIEW_OUTPUT" "$PWD/.build/test-modcache"
cat Sources/TaskStore.swift Tests/TaskStoreChecks.swift Tests/TaskMutationChecks.swift Tests/CraftChecks.swift Tests/MultilistChecks.swift > "$CHECK_DIR/TaskStore.swift"
cat Sources/NotchPanelController.swift Tests/ControllerChecks.swift Tests/MenuBarChecks.swift Tests/HoverEntryChecks.swift Tests/AnimationDemoChecks.swift > "$CHECK_DIR/Controller.swift"
sed -e 's/auxiliaryTopLeftArea/fixtureTopLeftArea/g' -e 's/auxiliaryTopRightArea/fixtureTopRightArea/g' Sources/Geometry.swift > "$CHECK_DIR/Geometry.swift"
swiftc -swift-version 5 -nonlib-dependency-scanner \
  -module-cache-path "$PWD/.build/test-modcache" \
  -framework AppKit -framework SwiftUI -framework EventKit -framework ServiceManagement \
  "$CHECK_DIR/TaskStore.swift" Sources/AppDelegate.swift Sources/PanelView.swift Sources/SettingsView.swift Sources/LoginItemManager.swift Sources/ReminderMutation.swift \
  "$CHECK_DIR/Geometry.swift" Sources/Theme.swift Sources/PanelFeedback.swift Sources/PanelRenderCache.swift "$CHECK_DIR/Controller.swift" \
  Tests/Support.swift Tests/LoginItemChecks.swift Tests/main.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check" | tee "$CHECK_DIR/output.log"
grep -q '^PASS all checks completed$' "$CHECK_DIR/output.log"
