#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
APP="$PWD/build/RecurrenceProbe.app"
WRITER_MODE="${1:-}"
CHECK_DIR=$(mktemp -d /private/tmp/glitter-mutation-probe.XXXXXX)
trap 'rm -rf "$CHECK_DIR"' EXIT
mkdir -p "$APP/Contents/MacOS" "$PWD/.build/probe-cache" "$PWD/build/review/recurrence-api"
cp Tests/Manual/RecurrenceProbe.swift "$CHECK_DIR/main.swift"
swiftc -swift-version 5 -nonlib-dependency-scanner \
  -module-cache-path "$PWD/.build/probe-cache" \
  -target arm64-apple-macosx14.0 \
  -framework AppKit -framework EventKit \
  Sources/TaskStore.swift Sources/ReminderMutation.swift Sources/PanelFeedback.swift "$CHECK_DIR/main.swift" -o "$APP/Contents/MacOS/RecurrenceProbe"
REPORT="probe-results.json"
if [[ "$WRITER_MODE" == "--writer" ]]; then REPORT="writer-results.json"; fi
python3 - "$APP" "$PWD/build/review/recurrence-api/$REPORT" "$WRITER_MODE" <<'PY'
import plistlib, pathlib, sys
app = pathlib.Path(sys.argv[1])
info = {
    'CFBundleIdentifier': 'com.sand.notch.recurrence-probe',
    'CFBundleName': 'Glitter API Test',
    'CFBundleDisplayName': 'Glitter API Test',
    'CFBundleExecutable': 'RecurrenceProbe',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.0',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '14.0',
    'NSRemindersFullAccessUsageDescription': 'Test completing and reopening fake recurring reminders in a new temporary list. Existing tasks are not read or changed.',
    'NSRemindersUsageDescription': 'Test fake recurring reminders in a new temporary list only.',
    'ProbeOutputPath': sys.argv[2],
    'ProductionWriterProbe': sys.argv[3] == '--writer',
}
with (app / 'Contents' / 'Info.plist').open('wb') as f:
    plistlib.dump(info, f)
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
