#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
xcodegen generate

if [[ ! -d /Applications/Xcode.app ]]; then
  echo "Xcode is not installed yet. Finish the App Store confirmation first."
  open "macappstore://itunes.apple.com/app/id497799835"
  read -k 1 "?Press any key to close."
  exit 1
fi

open -a Xcode AIRecorder.xcodeproj
