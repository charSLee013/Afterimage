#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT/app"
SDK=$(xcrun --sdk macosx --show-sdk-path)

for script in "$APP_DIR"/*.sh; do
  sh -n "$script"
done

plutil -lint \
  "$APP_DIR/LocalClips/Sources/Info.plist" \
  "$APP_DIR/LocalClips.xcodeproj/project.pbxproj"

set -- "$APP_DIR"/LocalClips/Sources/*.swift
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx27.0 \
  -swift-version 6 \
  -parse-as-library \
  -typecheck \
  -framework AppKit \
  -framework SwiftUI \
  -framework CoreData \
  -framework CoreGraphics \
  -framework Carbon \
  -framework ServiceManagement \
  -framework OSLog \
  -framework CryptoKit \
  "$@"

printf 'Static checks passed (Swift 6 arm64, shell, plist/project).\n'
