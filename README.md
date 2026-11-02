# LocalClips

Native clipboard history for Apple silicon Macs.

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

LocalClips saves copied content on your Mac so you can search, pin, and restore it later.

## Features

- Capture text, rich text, images, links, and ordered multi-item clips.
- Search history and organize items in Pinboards.
- Restore original formatting or use plain text; automatic paste is optional.
- Store file clips as references. Original files are not copied or changed.

## Install

Requires an Apple silicon Mac running macOS 27 or later.

```sh
./app/build.sh
./app/install.sh
open "$HOME/Applications/LocalClips.app"
```

Recording is off on first launch. Enable it in the app and grant macOS permissions when prompted. To update, quit LocalClips and run `./app/install.sh --replace-existing`.

This personal-use build is ad-hoc signed and not notarized. Return-key and input-method behavior still needs in-app verification.

## Data and privacy

History is stored in `~/Library/Application Support/LocalClips/`. LocalClips does not encrypt this data or sync it to the cloud. File clips keep references to the original files. To erase LocalClips data, quit the app and remove its folders from Application Support and Caches.

## Development

```sh
./app/check.sh
./app/test-adr-0002.sh
./app/build.sh
```

GitHub Actions runs static checks, isolated regression tests, and a native arm64 build on macOS 27.
