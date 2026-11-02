#!/usr/bin/env bash
# Debug simulator build + clean install (an old install keeps a stale scene session and launches black).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${SIM_UDID:-E12D2A14-BBCA-44B0-9D19-5B5F0FE03279}"
BUNDLE="${BUNDLE_ID:-com.samyakjain.antcloud}"
[[ -z "${DEVELOPER_DIR:-}" ]] && export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | head -1)/Contents/Developer"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcodebuild -project "$here/moonlight-ios/Moonlight.xcodeproj" -scheme Moonlight -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$here/moonlight-ios/build-sim" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build 2>&1 | grep -E "error:|BUILD"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$here/moonlight-ios/build-sim/Build/Products/Debug-iphonesimulator/Moonlight.app"
