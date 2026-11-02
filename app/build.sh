#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT/app"
ARTIFACTS="$ROOT/artifacts"
APP="$ARTIFACTS/LocalClips.app"
SDK=$(xcrun --sdk macosx --show-sdk-path)

mkdir -p "$ARTIFACTS" "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
set -- "$APP_DIR"/LocalClips/Sources/*.swift
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx27.0 \
  -swift-version 6 \
  -O \
  -parse-as-library \
  -framework AppKit \
  -framework SwiftUI \
  -framework CoreData \
  -framework CoreGraphics \
  -framework Carbon \
  -framework ServiceManagement \
  -framework OSLog \
  -framework CryptoKit \
  "$@" \
  -o "$APP/Contents/MacOS/LocalClips"
xcrun momc \
  --sdkroot="$SDK" \
  --macosx-deployment-target=27.0 \
  --action compile \
  "$APP_DIR/LocalClips/Models/LocalClips.xcdatamodeld" \
  "$APP/Contents/Resources/LocalClips.momd"
cp "$APP_DIR/LocalClips/Sources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - --timestamp=none "$APP"

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "local.charslee.localclips"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")" = "true"
codesign --verify --deep --strict "$APP"
file "$APP/Contents/MacOS/LocalClips"
printf 'Built: %s\n' "$APP"
