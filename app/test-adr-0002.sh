#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT/app"
SDK=$(xcrun --sdk macosx --show-sdk-path)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/localclips-adr0002.XXXXXX")
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

xcrun momc \
  --sdkroot="$SDK" \
  --macosx-deployment-target=27.0 \
  --action compile \
  "$APP_DIR/LocalClips/Models/LocalClips.xcdatamodeld" \
  "$TEMP_ROOT/LocalClips.momd"

xcrun swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx27.0 \
  -swift-version 6 \
  -parse-as-library \
  -framework AppKit \
  -framework CoreData \
  -framework CryptoKit \
  -framework OSLog \
  "$APP_DIR/LocalClips/Sources/Domain.swift" \
  "$APP_DIR/LocalClips/Sources/HistoryStore.swift" \
  "$APP_DIR/LocalClips/Sources/ClipboardRecorder.swift" \
  "$APP_DIR/Tests/ADR0002Regression.swift" \
  -o "$TEMP_ROOT/ADR0002Regression"

"$TEMP_ROOT/ADR0002Regression" "$TEMP_ROOT/LocalClips.momd" "$TEMP_ROOT"
