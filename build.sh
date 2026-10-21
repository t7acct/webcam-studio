#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Webcam Studio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -g -target arm64-apple-macos15.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" Sources/*.swift \
  -o "$APP/Contents/MacOS/WebcamStudio" \
  -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework CoreImage -framework MetalKit -framework AudioToolbox -framework Vision -framework ImageIO
cp Resources/Info.plist "$APP/Contents/Info.plist"
# A stable local identity keeps the app's privacy permissions across rebuilds.
# Override with SIGN_IDENTITY=- for ad-hoc signing on a machine without a certificate.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)}"
codesign --force --sign "${IDENTITY:--}" --entitlements Resources/WebcamStudio.entitlements "$APP"
echo "$APP"
