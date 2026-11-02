#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/artifacts/LocalClips.app"
DESTINATION="$HOME/Applications/LocalClips.app"
REPLACE=0

if [ "${1-}" = "--replace-existing" ] && [ "$#" -eq 1 ]; then
  REPLACE=1
elif [ "$#" -ne 0 ]; then
  printf 'Usage: %s [--replace-existing]\n' "$0" >&2
  exit 2
fi

test -d "$SOURCE" || { printf 'Build first: %s\n' "$ROOT/app/build.sh" >&2; exit 1; }
if [ -e "$DESTINATION" ]; then
  if [ "$REPLACE" -ne 1 ]; then
    printf 'Refusing to overwrite existing path: %s\nUse --replace-existing only for a verified LocalClips installation after quitting it.\n' "$DESTINATION" >&2
    exit 2
  fi
  IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)
  if [ "$IDENTIFIER" != "local.charslee.localclips" ]; then
    printf 'Refusing to replace unrecognized bundle at %s\n' "$DESTINATION" >&2
    exit 3
  fi
  codesign --verify --deep --strict "$DESTINATION"
  if /usr/bin/pgrep -x LocalClips >/dev/null 2>&1; then
    printf 'Quit LocalClips normally before replacing its app bundle.\n' >&2
    exit 4
  fi
else
  mkdir -p "$HOME/Applications"
fi
ditto "$SOURCE" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
printf 'Installed: %s\n' "$DESTINATION"
