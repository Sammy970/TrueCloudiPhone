#!/usr/bin/env bash
# Builds an unsigned IPA for sharing: dist/TrueCloud-<version>.ipa.
#
# No signature, no provisioning profile and no personal details: people install it with SideStore,
# AltStore or Sideloadly, which sign it with their own Apple ID (and SideStore/AltStore re-sign it
# every 7 days). Built in Debug on purpose: Moonlight's Release build only accepts local network
# addresses, and a cloud PC isn't on your network. Your own signed build (scripts/renew-and-install.sh)
# uses a separate build folder and isn't touched.
#
# Usage: scripts/make-ipa.sh [--integrate]     (MOONLIGHT=<path> if moonlight-ios isn't next to this repo)
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
MOONLIGHT="${MOONLIGHT:-$here/moonlight-ios}"
[[ -d "$MOONLIGHT" ]] || { echo "moonlight-ios not found at $MOONLIGHT" >&2; exit 1; }
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer"
fi
[[ "${1:-}" == "--integrate" ]] && ruby "$here/integrate-moonlight.rb" "$MOONLIGHT"

VERSION=$(sed -nE 's/.*static let appVersion = "([0-9.]+)".*/\1/p' "$here/Sources/Shared/Config.swift")
BUILD=$(git -C "$here" rev-list --count HEAD 2>/dev/null || echo 1)
DERIVED="$MOONLIGHT/build-unsigned"
APP="$DERIVED/Build/Products/Debug-iphoneos/Moonlight.app"

echo "Building unsigned TrueCloud $VERSION ($BUILD)…"
log="$(mktemp)"
if ! xcodebuild -project "$MOONLIGHT/Moonlight.xcodeproj" -scheme Moonlight -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
    PRODUCT_BUNDLE_IDENTIFIER=io.github.sammy970.truecloud \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    ENABLE_DEBUG_DYLIB=NO DEBUG_INFORMATION_FORMAT=dwarf \
    OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $HOME=/src" \
    OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$HOME=/src" \
    build >"$log" 2>&1; then
  grep -E "error:" "$log" | head -20 >&2
  echo "Build failed. Full log: $log" >&2
  exit 1
fi
rm -f "$log"

# Source paths the compilers record (e.g. Swift's #file) are rewritten from your home folder to /src
# above, so nothing in the IPA names the machine it was built on.

# Package: an IPA is a zip with the app inside Payload/.
out="$here/dist"
rm -rf "$out/Payload"
mkdir -p "$out/Payload"
cp -R "$APP" "$out/Payload/TrueCloud.app"
rm -rf "$out/Payload/TrueCloud.app/_CodeSignature" "$out/Payload/TrueCloud.app/embedded.mobileprovision"
# Swift packages (Socket.IO) ignore the prefix-map flags and keep their #file paths, which start with
# this machine's folders. Rewrite any such path in the binaries to an equal-length neutral one.
python3 -I - "$out/Payload/TrueCloud.app" "$(cd "$here/.." && pwd)" "$HOME" <<'PY'
import pathlib, sys
app, root, home = pathlib.Path(sys.argv[1]), sys.argv[2].encode(), sys.argv[3].encode()
def neutral(prefix: bytes) -> bytes:
    return (b"/src" + b"/" * len(prefix))[:len(prefix)]
for f in app.rglob("*"):
    if not f.is_file():
        continue
    data = f.read_bytes()
    new = data.replace(root, neutral(root)).replace(home, neutral(home))
    if new != data:
        f.write_bytes(new)
        print(f"  neutralised build paths in {f.relative_to(app)}")
PY
IPA="$out/TrueCloud-$VERSION.ipa"
rm -f "$IPA"
(cd "$out" && zip -qry "$(basename "$IPA")" Payload)
rm -rf "$out/Payload"
echo "Built $IPA ($(du -h "$IPA" | cut -f1))"
