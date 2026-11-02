# LocalClips

## Implementation status

The scoped code changes in [ADR-0002](docs/adr/0002-capture-query-keyboard-fixes.md) are implemented. Real panel and input-method checks R12-R14 remain unverified; see the [acceptance report](../artifacts/ADR-0002-ACCEPTANCE.md). The original full-product PRD is a requirements baseline and is not the completion gate for ADR-0002.

Native local macOS clipboard manager. Targets macOS 27.0 and later on arm64; validated host is macOS 27.0.1 with Xcode 27.2 / SDK 27.2.

## Build

From the workspace root:

```sh
./app/build.sh
```

This builds a native arm64 app with an ad-hoc local signature into `artifacts/LocalClips.app`, using the selected Xcode's `swiftc` and `momc`. It uses no third-party packages, Apple developer membership, cloud service, or network access at runtime. The app is not Developer ID signed or notarized and is intended for this Mac only.

The workspace includes `LocalClips.xcodeproj` and a shared `LocalClips` scheme. On this host, `xcodebuild -list` currently fails before project loading because Xcode 27.2 cannot load `IDESimulatorFoundation` without `/Library/Developer/PrivateFrameworks/DVTDownloads.framework`. The reproducible build script avoids that broken plug-in and invokes the Xcode toolchain directly. It does not run `xcodebuild -runFirstLaunch` or install system components.

## Install and run

```sh
./app/install.sh
open "$HOME/Applications/LocalClips.app"
```

The installer refuses to replace an existing `~/Applications/LocalClips.app`. To update a verified LocalClips copy, quit it normally, then run `./app/install.sh --replace-existing`; the script checks its Bundle ID and signature and refuses while any LocalClips process is running. The first run creates or migrates the Core Data SQLite store under `~/Library/Application Support/LocalClips/`. Recording starts disabled until the user reads the in-app notice and selects **开始记录**. The current clipboard becomes the baseline and is not imported.

Use the menu-bar item to open history or explicitly quit. Closing the panel leaves an enabled recorder running. Pause state persists across launches. Data remains local and is not encrypted by the app. Remove the app from `~/Applications` to uninstall. To erase LocalClips history, quit the app, then remove `~/Library/Application Support/LocalClips` and, if present, `~/Library/Caches/LocalClips`; that erases only LocalClips data. System privacy approvals are controlled in System Settings and are not changed by installation or cleanup.

## Content deduplication

Copies of the same text share one history record across applications, even when HTML/RTF formatting differs. The most recent copy updates the timestamp, source display and full restoration representations while preserving the record UUID, original creation date and Pinboards. Line endings and canonically equivalent Unicode are normalized for identity; meaningful spaces and letter case remain distinct.

Repeated copies of the same file URL share one reference record; bookmarks and display labels do not split it. Separate file paths remain separate references. Exact representation matching is retained for non-text/non-file payloads such as images.

On first launch with this version, legacy records with complete representations are consolidated transactionally. The earliest record identity and all Pinboard relationships survive; the most recent copied representations are retained. Legacy records without a usable content identity are preserved and excluded from consolidation. The exact payload digest used for self-restoration remains separate from content identity.

Run `./app/test-adr-0002.sh` for the isolated content and ADR-0002 regressions, or set `LOCALCLIPS_CONTENT_ONLY=1` to run only the content regressions. These tests use temporary synthetic stores; they do not satisfy the PRD's real-path AC14 or modify the user's database.

## Signing and permissions

`codesign -dv --verbose=4 ~/Applications/LocalClips.app` shows the local ad-hoc signature. Rebuilding changes the executable identity and may require the user to review privacy approvals again. No TCC database is modified. Clipboard-read and event-posting requests are initiated only by the user through the app; review the actual results in the app and System Settings. Login startup is opt-in. If SMAppService rejects this local signature, use the system's Login Items UI and verify a real login before considering it enabled. Do not use this ad-hoc build for public distribution.
