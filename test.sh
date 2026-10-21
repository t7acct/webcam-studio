#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 \
  Sources/CaptureEngine.swift Sources/Enhancement.swift Sources/BackgroundEffects.swift Sources/MetalPreview.swift Sources/Recording.swift Tests/Checks.swift \
  -o build/Checks -framework SwiftUI -framework AVFoundation -framework CoreImage -framework MetalKit -framework AudioToolbox -framework Vision -framework ImageIO
./build/Checks
