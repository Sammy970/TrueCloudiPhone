#!/usr/bin/env bash
# Debug previews in the iOS 26.5 iPhone 17 Pro simulator: scripts/sim-shot.sh <preview> <name> [wait-seconds]
# e.g. scripts/sim-shot.sh home:ready ready. Needs a Debug simulator build (see README) installed on the simulator.
set -euo pipefail
[[ -z "${DEVELOPER_DIR:-}" ]] && export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | head -1)/Contents/Developer"
UDID="${SIM_UDID:-E12D2A14-BBCA-44B0-9D19-5B5F0FE03279}"
here="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="${BUNDLE_ID:-com.samyakjain.antcloud}"
mkdir -p "$here/.github/screenshots"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
SIMCTL_CHILD_TRUECLOUD_PREVIEW="$1" SIMCTL_CHILD_TRUECLOUD_APPEARANCE="${APPEARANCE:-}" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
sleep "${3:-6}"
xcrun simctl io "$UDID" screenshot "$here/.github/screenshots/$2.png" >/dev/null 2>&1
echo "$here/.github/screenshots/$2.png"
