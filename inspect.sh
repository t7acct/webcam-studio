#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -O -target arm64-apple-macos15.0 Tests/InspectRecording.swift -parse-as-library -o build/InspectRecording -framework AVFoundation -framework AudioToolbox
exec ./build/InspectRecording "$@"
