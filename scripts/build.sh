#!/bin/bash
# Builds Inkboard with plain swiftc and packages build/Inkboard.app (`swift build` only makes a bare binary).
#
#   scripts/build.sh            release build
#   scripts/build.sh debug      debug build
#   scripts/build.sh check      build, then run the core self-check
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
OBJ="$BUILD/obj"
MODE="${1:-release}"

OPT=(-O)
[ "$MODE" = "debug" ] && OPT=(-Onone -g)
COMMON=("${OPT[@]}" -target "$(uname -m)-apple-macos13.0" -swift-version 5)

mkdir -p "$OBJ"

echo "• InkboardCore"
swiftc "${COMMON[@]}" -parse-as-library -module-name InkboardCore \
    -emit-module -emit-module-path "$OBJ/InkboardCore.swiftmodule" \
    -emit-library -static -o "$OBJ/libInkboardCore.a" \
    "$ROOT"/Sources/InkboardCore/*.swift

echo "• Inkboard (app)"
swiftc "${COMMON[@]}" -module-name Inkboard -I "$OBJ" -L "$OBJ" -lInkboardCore \
    "$ROOT"/Sources/Inkboard/*.swift -o "$OBJ/Inkboard"

echo "• InkboardCheck"
swiftc "${COMMON[@]}" -module-name InkboardCheck -I "$OBJ" -L "$OBJ" -lInkboardCore \
    "$ROOT"/Sources/InkboardCheck/*.swift -o "$OBJ/InkboardCheck"

APP="$BUILD/Inkboard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OBJ/Inkboard" "$APP/Contents/MacOS/Inkboard"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc codesign skipped)"
# Register with Launch Services so Finder knows .inkboard files open with this app.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
echo "✓ $APP"

if [ "$MODE" = "check" ]; then
    echo
    "$OBJ/InkboardCheck" "$BUILD/sample.png"
fi
