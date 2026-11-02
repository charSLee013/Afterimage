# LocalClips

Appleシリコン搭載 Mac 向けのネイティブなクリップボード履歴アプリです。

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

コピーした内容を Mac 内に保存し、検索、ピン留め、復元できます。

## 機能

- テキスト、リッチテキスト、画像、リンク、順序付きの複数項目を保存。
- 履歴を検索し、Pinboard で整理。
- 元の形式またはプレーンテキストで復元。自動ペーストも選択可能。
- ファイルは参照のみを保存。元ファイルはコピーも変更もしません。

## インストール

Apple silicon 搭載 Mac と macOS 27 以降が必要です。

```sh
./app/build.sh
./app/install.sh
open "$HOME/Applications/LocalClips.app"
```

初回起動時は記録がオフです。アプリで有効にし、macOS の許可を求められた場合は設定してください。更新時は LocalClips を終了してから `./app/install.sh --replace-existing` を実行します。

個人利用向けのローカル署名ビルドで、公証はありません。Return キーと入力メソッドの動作はアプリ上で未検証です。

## データとプライバシー

履歴は `~/Library/Application Support/LocalClips/` に保存されます。アプリによる暗号化やクラウド同期はありません。ファイル項目には元ファイルへの参照のみを保存します。データを消去するには、アプリを終了して Application Support と Caches 内の LocalClips フォルダーを削除してください。

## 開発

```sh
./app/check.sh
./app/test-adr-0002.sh
./app/build.sh
```

GitHub Actions は macOS 27 上で静的チェック、分離された回帰テスト、arm64 ネイティブビルドを実行します。
