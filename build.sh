#!/bin/sh
# Build Atoll.app (minimal bundle so Login Items / Gatekeeper are happy).
# Usage: ./build.sh [--universal]
#   --universal   build arm64 + x86_64 (used by CI for releases)
#   VERSION=x.y.z overrides the version (defaults to latest git tag)
set -e
cd "$(dirname "$0")"
APP="Atoll.app"
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"

if [ "$1" = "--universal" ]; then
  set -- --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/Atoll"
else
  set --
  BIN=".build/release/Atoll"
fi

# native build system: swiftbuild (Swift 6.4+) compiles SwiftTerm's .metal
# shader, and `metal` only ships with Xcode
build() { swift build -c release --build-system native "$@"; }

# Command Line Tools alone: a newer default SDK can need Xcode-only macro
# plugins (SwiftUI @State in the 27 SDK) — fall back to older SDKs
if ! build "$@"; then
  [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ] || exit 1
  ok=
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.*.sdk | sort -rV); do
    [ "$sdk" -ef "$(xcrun --show-sdk-path)" ] && continue
    echo "retrying with $(basename "$sdk")"
    if SDKROOT="$sdk" build "$@"; then ok=1; break; fi
  done
  [ -n "$ok" ] || exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Atoll"
# scriptable control binary; NOT "atoll" — APFS is case-insensitive and it
# would clobber the Atoll app binary
cp "$(dirname "$BIN")/atoll-cli" "$APP/Contents/MacOS/atollctl"
cp AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Atoll</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>dev.pj.atoll</string>
  <key>CFBundleName</key><string>Atoll</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign -s - --force "$APP" 2>/dev/null || true
echo "built: $PWD/$APP (v$VERSION)"

# keep the installed copy in sync
if [ -d "/Applications/$APP" ]; then
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "updated: /Applications/$APP"
fi
