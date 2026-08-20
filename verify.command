#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

echo "1/7 Checking BK7258 protocol and local models"
swift run recorder-core-check

echo "2/7 Parsing all Swift source"
swiftc -frontend -parse $(rg --files AIRecorder Sources/RecorderCore -g '*.swift')

echo "3/7 Type-checking the complete app"
swiftc -typecheck -parse-as-library -target arm64-apple-macosx14.0 \
  $(rg --files AIRecorder Sources/RecorderCore -g '*.swift' | sort)

echo "4/7 Generating the Xcode project"
xcodegen generate

echo "5/7 Checking the P0 app surface and manifests"
plutil -lint AIRecorder/Info.plist AIRecorder/AIRecorder.entitlements >/dev/null
if rg -n 'PhoneRecordingView|SettingsView|Try Demo Mode|Record with iPhone|BackendClient|DeepgramClient' \
  AIRecorder/Views/ContentView.swift \
  AIRecorder/Views/DeviceView.swift \
  AIRecorder/Views/LibraryView.swift; then
  echo "BLOCKED: A non-wearable control is still reachable from the P0 UI." >&2
  exit 2
fi

if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  simulator_id="$(
    xcrun simctl list devices available |
      awk -F '[()]' '/iPhone/ { print $2; exit }'
  )"
  if [[ -z "$simulator_id" ]]; then
    echo "BLOCKED: No available iPhone simulator was found." >&2
    exit 2
  fi

  echo "6/7 Running the iPhone simulator test suite"
  xcodebuild \
    -project AIRecorder.xcodeproj \
    -scheme AIRecorder \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath build/DerivedData-verify-tests \
    CODE_SIGNING_ALLOWED=NO \
    test

  echo "7/7 Compiling the production arm64 iPhone build"
  xcodebuild \
    -project AIRecorder.xcodeproj \
    -scheme AIRecorder \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/DerivedData-verify-release \
    CODE_SIGNING_ALLOWED=NO \
    build
else
  echo "BLOCKED: Full Xcode is required for simulator tests and the iPhone Release build." >&2
  exit 2
fi

echo "PASS: all seven Dawn Recorder verification gates passed."
