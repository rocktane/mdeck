#!/bin/bash
# Builds mdeck.app from the Swift sources. No Xcode project, no SwiftPM manifest: one swiftc
# invocation over every file under Sources/ plus a hand-rolled bundle.
#
#   ./build.sh                     native build, signed with "mdeck Signing" if that
#                                  certificate exists (`make cert`), ad hoc otherwise
#   ./build.sh --debug             also compiles the debug helpers (--snapshot-settings, …)
#   ./build.sh --universal         arm64 + x86_64
#   ./build.sh --reset-permission  clears a stale Accessibility grant
set -euo pipefail
cd "$(dirname "$0")"

APP="build/mdeck.app"
CODESIGN_ID="${CODESIGN_ID:-mdeck Signing}"
DEBUG=0
UNIVERSAL=0
RESET=0
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG=1 ;;
    --universal) UNIVERSAL=1 ;;
    --reset-permission) RESET=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon: Assets/icon-1024.png (drawn by scripts/make-icon.swift) → .icns, cached in build/.
[[ -f Assets/icon-1024.png ]] || swift scripts/make-icon.swift Assets/icon-1024.png
ICNS=build/mdeck.icns
if [[ ! -f "$ICNS" || Assets/icon-1024.png -nt "$ICNS" ]]; then
  ICONSET=build/mdeck.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Assets/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Assets/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONSET"
fi
cp "$ICNS" "$APP/Contents/Resources/mdeck.icns"

# Every module lives in its own folder; they are all one module for the compiler.
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' -print0 | sort -z)

# -wmo: without whole-module optimization the files are still compiled as separate units and
# nothing is inlined or specialized across them.
FLAGS=(-O -wmo)
[[ $DEBUG == 1 ]] && FLAGS+=(-D DEBUG)

compile() { # arch, output
  swiftc "${FLAGS[@]}" -target "$1-apple-macos13.0" \
    -framework Cocoa -framework Carbon -framework ApplicationServices -framework ServiceManagement \
    -o "$2" "${SOURCES[@]}"
}

BIN="$APP/Contents/MacOS/mdeck"
if [[ $UNIVERSAL == 1 ]]; then
  compile arm64 build/mdeck-arm64
  compile x86_64 build/mdeck-x86_64
  lipo -create build/mdeck-arm64 build/mdeck-x86_64 -output "$BIN"
  rm -f build/mdeck-arm64 build/mdeck-x86_64
else
  compile "$(uname -m)" "$BIN"
fi

# Signing. The Accessibility grant is bound to the code identity: with the certificate it is
# "com.yohan.mdeck signed by mdeck Signing" and survives rebuilds; ad hoc, it is the code hash
# and dies with every change to the sources.
if security find-certificate -c "$CODESIGN_ID" >/dev/null 2>&1; then
  codesign --force --sign "$CODESIGN_ID" --options runtime "$APP"
  SIGNED="signed: $CODESIGN_ID"
else
  codesign --force --sign - "$APP" 2>/dev/null || true
  SIGNED="signed: ad hoc (run 'make cert' for a stable identity)"
fi

if [[ $RESET == 1 ]]; then
  tccutil reset Accessibility com.yohan.mdeck >/dev/null 2>&1 || true
  echo "accessibility grant reset"
fi

echo "built $APP ($SIGNED$([[ $UNIVERSAL == 1 ]] && echo ', universal')$([[ $DEBUG == 1 ]] && echo ', debug'))"
