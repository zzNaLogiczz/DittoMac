# DittoMac

**English** | [中文](#中文)

A native macOS (Apple Silicon) clipboard manager, rebuilt from the ground up in Swift/AppKit —
following the behavior specification of the open-source Windows clipboard manager
[Ditto](https://github.com/sabrogden/Ditto). Zero third-party dependencies.

## Install

**One-line install (recommended, no Gatekeeper prompts):**

```zsh
curl -fsSL https://raw.githubusercontent.com/<USER>/ditto-mac/main/scripts/install.sh | zsh
```

**Manual download (DMG):** grab `DittoMac-vX.Y.Z-arm64.dmg` from
[Releases](../../releases), open it and drag `DittoMac.app` onto the `Applications`
shortcut. A plain `tar.gz` is also available. Because the app is not notarized
(no paid Apple Developer account), macOS may warn on first launch: right-click → Open,
or System Settings → Privacy & Security → "Open Anyway".

> Requires macOS 13+, Apple Silicon (arm64).

**First run:** grant Accessibility permission (System Settings → Privacy & Security →
Accessibility → enable DittoMac). This is required by macOS for simulating ⌘V — the same
permission every Mac clipboard manager asks for. Until granted, selected clips are only
copied to the clipboard.

## Usage

- `⌘⇧V` (configurable, click-to-record in Settings) opens the Quick Paste panel
- `↑↓` navigate · `Enter`/double-click paste · `⇧Enter` paste as plain text · `⌥Enter` properties
- `⌘1..0` paste the first ten items · type anywhere to search · `Esc` dismiss (3-level)
- Hover any item for the full content in a floating panel; right-click menu: Special Paste
  (case transforms, line feeds, multiple-image merge, Typoglycemia, Slugify, new GUID,
  paste-as-image…), Clip Order, Export
- Items can be pinned (immune to cleanup), marked "never auto delete"; pasted items show a
  green indicator; history is capped by count/age settings

## What it replicates from Ditto

Multi-format clip storage (text/RTF/HTML/image/files coexist in one entry and are restored
together), duplicate detection that bumps the old entry to top, bottom search bar with
find-as-you-type, the right-side vertical caption bar, the full Quick Paste window layout,
the keyboard map, and the context-menu tree — all replicated 1:1 against 38 checkpoints
extracted from the original source and validated by 5 rounds of independent QA scoring
(final scores: 11/11 dimensions ≥ 9.5/10).

Not ported (yet): LAN sync, groups/tree, per-entry hot keys, clip editor, QR codes.

## Build from source

```zsh
git clone <this repo> && cd ditto-mac
swift build -c release
./scripts/make-app.sh      # → DittoMac.app (arm64)
./scripts/make-dmg.sh      # → DittoMac-vX.Y.Z-arm64.dmg
./scripts/run-tests.sh     # 53 tests (no Xcode needed, CLT is enough)
```

## Release automation

Pushing a tag (`v1.2.3`) runs GitHub Actions: tests → build → package `tar.gz` + `dmg` →
attach to the GitHub Release. The one-line install script streams the tarball via `curl`,
so files never get the quarantine attribute and Gatekeeper never complains.

Optional: set repo secrets `DITTOMAC_SIGN_P12` (base64 of a p12) and
`DITTOMAC_SIGN_PASSWORD` to sign releases with a stable self-signed certificate —
users then keep their Accessibility grant across app updates.

## Resources

`Resources/icon-source.png` is the 256px layer extracted from the original Ditto
`Ditto2.ico`; regenerate `AppIcon.icns` with:

```zsh
mkdir -p Resources/AppIcon.iconset
for s in 16 32 64 128 256 512; do
  sips -z $s $s Resources/icon-source.png --out Resources/AppIcon.iconset/icon_${s}x${s}.png
done
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

## License

GPL-3.0 — this project follows the license of Ditto, whose behavior specification it is
derived from. See [LICENSE](LICENSE). The application icon is taken from the Ditto
repository. Not affiliated with the original Ditto project.

---

# 中文

一个原生 macOS(Apple Silicon)剪贴板管理器,以 Swift/AppKit 从零重写,
行为规格逐条对照 Windows 开源软件 [Ditto](https://github.com/sabrogden/Ditto)。
零第三方依赖。

## 安装

**一行命令安装(推荐,无 Gatekeeper 拦截):**

```zsh
curl -fsSL https://raw.githubusercontent.com/<USER>/ditto-mac/main/scripts/install.sh | zsh
```

**手动下载(DMG)**:从 [Releases](../../releases) 下载 `DittoMac-vX.Y.Z-arm64.dmg`,
打开后把 `DittoMac.app` 拖到 `Applications` 快捷方式即可(也提供 `tar.gz`)。
因未做公证(需要付费开发者账号),首次打开如遇警告:
右键 → 打开,或到 系统设置 → 隐私与安全性 → "仍要打开"。

> 需要 macOS 13+ 与 Apple Silicon 芯片。

**首次使用**:请在 系统设置 → 隐私与安全性 → 辅助功能 中打开 DittoMac——
模拟 ⌘V 粘贴回原位置必须要有这个权限(所有 Mac 剪贴板工具都一样)。
未授权时选中条目只会复制到剪贴板,手动 ⌘V 即可。

## 使用

- `⌘⇧V`(可在设置里点按录制修改)打开快速粘贴面板
- `↑↓` 选择 · `回车`/双击 粘贴 · `⇧回车` 纯文本粘贴 · `⌥回车` 属性
- `⌘1..0` 粘贴前十条 · 任意位置直接打字搜索 · `Esc` 三级退出
- 鼠标悬停任意条目,左侧浮窗展示完整内容
- 右键菜单:特殊粘贴(大小写变换/换行处理/多图合成/Typoglycemia/Slugify/新 GUID/贴为图片…)、
  条目顺序、导入导出
- 支持置顶、永不自动删除、已粘贴绿条指示;历史按条数/天数自动清理

## 从源码构建

```zsh
git clone <本仓库> && cd ditto-mac
swift build -c release
./scripts/make-app.sh      # → DittoMac.app(arm64)
./scripts/make-dmg.sh      # → DittoMac-vX.Y.Z-arm64.dmg
./scripts/run-tests.sh     # 53 项测试(仅需 Command Line Tools)
```

## 发布自动化

推送 tag(`v1.2.3`)会触发 GitHub Actions:测试 → 构建 → 打包 `tar.gz` + `dmg` → 上传到 Release。
一键安装脚本用 `curl` 流式解压,文件不带隔离属性,Gatekeeper 不会拦截。

可选:配置仓库 Secret `DITTOMAC_SIGN_P12`(p12 的 base64)与 `DITTOMAC_SIGN_PASSWORD`,
用稳定的自签名证书给发布版签名——用户更新版本时辅助功能授权保持有效。

## 许可

GPL-3.0(跟随 Ditto 的许可证,本项目衍生自其行为规格)。见 [LICENSE](LICENSE)。
应用图标取自 Ditto 仓库。与原 Ditto 项目无隶属关系。
