# LocalClips

为 Apple 芯片 Mac 打造的原生剪贴板历史管理器。

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

LocalClips 将复制的内容保存在本机，方便搜索、收藏和恢复。

## 功能

- 保存文本、富文本、图片、链接及有序的多项目剪贴板内容。
- 搜索历史记录，并用 Pinboard 整理收藏。
- 按原格式或纯文本恢复；可选择自动粘贴。
- 文件仅保存引用，不复制或修改原文件。

## 安装

需要 Apple 芯片 Mac 和 macOS 27 或更高版本。

```sh
./app/build.sh
./app/install.sh
open "$HOME/Applications/LocalClips.app"
```

首次启动时记录功能默认关闭，请在应用中启用；macOS 提示时按需授权。更新前先退出 LocalClips，再运行 `./app/install.sh --replace-existing`。

此版本供个人使用，采用本地签名，未经公证。Return 键和输入法行为仍待在应用中验证。

## 数据与隐私

历史记录保存在 `~/Library/Application Support/LocalClips/`。应用不会加密本地数据，也不提供云同步。文件记录只保存原文件引用。清除数据前先退出应用，再删除 LocalClips 的 Application Support 和 Caches 文件夹。

## 开发

```sh
./app/check.sh
./app/test-adr-0002.sh
./app/build.sh
```

GitHub Actions 会在 macOS 27 上运行静态检查、隔离回归测试和原生 arm64 构建。
