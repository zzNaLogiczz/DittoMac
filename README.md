# DittoMac — Ditto for macOS

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

**DittoMac brings [Ditto](https://github.com/sabrogden/Ditto) — the open-source Windows
clipboard manager — to the Mac.** It is a native macOS app rebuilt from the ground up in
Swift/AppKit on the basis of the original Ditto's source code and behavior specification,
with one goal: **give Mac users the same experience Ditto users have on Windows.**

The Quick Paste window, the keyboard map, the context menus, multi-format clip handling,
dedup-with-bump-to-top, paste-back with clipboard restore — every behavior was replicated 1:1
against 38 checkpoints extracted from the original source and validated through 5 rounds of
independent QA scoring, then rebuilt with a native macOS look & feel.

![Chinese UI](screenshots/panel-zh.png)
![English UI](screenshots/panel-en.png)

*UI: 中文 / English — switchable in Settings, effective immediately.*

## Requirements

| | |
|---|---|
| System | **macOS 13 Ventura** or later |
| Architecture | **Apple Silicon (arm64)** |
| Permissions | Accessibility (for simulating ⌘V — the same permission every Mac clipboard manager needs) |
| Dependencies | None. Zero third-party packages; building needs only Command Line Tools, no Xcode |

## Install

**One-line install (recommended — no Gatekeeper prompts):**

```zsh
curl -fsSL https://raw.githubusercontent.com/<USER>/ditto-mac/main/scripts/install.sh | zsh
```

**Manual (DMG):** download `DittoMac-vX.Y.Z-arm64.dmg` from
[Releases](../../releases), open it and drag `DittoMac.app` onto the `Applications` shortcut.

> The app is signed with a self-signed certificate (no paid Apple Developer account, so it is
> not notarized). If macOS warns on first launch: right-click → Open, or
> System Settings → Privacy & Security → "Open Anyway". The one-line installer avoids this
> entirely — files streamed via `curl` never get the quarantine attribute.

**First run:** grant the Accessibility permission when prompted
(System Settings → Privacy & Security → Accessibility → DittoMac). Until granted, selecting
an entry still copies it to the clipboard — paste manually with ⌘V.

## Features

**Capture & storage**
- Records the clipboard automatically: text, rich text (RTF), HTML, images and files —
  one entry keeps **all formats together** and pastes them back exactly as copied
- Re-copying existing content bumps the old entry to the top instead of duplicating
  (Ditto's classic behavior)
- SQLite (WAL) persistence — history survives restarts; a corrupted database is detected,
  backed up and rebuilt automatically
- Password-manager clips (`org.nspasteboard.ConcealedType`) are never recorded
- Retention by count and age; pinned and "never auto delete" entries are always kept

**Quick Paste window** (open with `⌘⇧V`; the hot key is click-to-record customizable)
- Borderless panel with Ditto's signature right-side vertical caption bar
  (close / roll-up / maximize / minimize, live title `ditto-mac - 1/9`), appearing at the cursor
- Single-column list: top-ten number badges, sticky pins, never-delete stars, green
  "has been pasted" bars, inline image thumbnails, color swatches for `#RRGGBB`-style text,
  red search-hit highlighting, relative timestamps
- Bottom search bar with find-as-you-type: multi-term AND, `OR`, `NOT`, `"quoted phrases"`,
  `*` wildcards; 10-entry search history
- Hover any entry to see its **full content** in a floating panel beside the list

**Paste-back**
- Enter / double-click writes the entry to the clipboard, simulates ⌘V at the original
  insertion point, then restores your previous clipboard after 0.4 s
- ⇧Enter pastes plain text only; multi-select aggregates; multiple images merge
  horizontally or vertically
- **Special Paste** — the full 21-item submenu from the original: case transforms, Trim,
  Posixify/Paths, CamelCase, ASCII-only, line-feed variants, paste-with-timestamp,
  Typoglycemia, Slugify, new GUID, paste-as-image, don't-reorder…

**Management**
- Clip Order (Move to Top/Up/Down/Last), sticky pinning, never-auto-delete, per-entry
  Properties window, filter-on-selected, delete/clear (protected entries survive)
- Import/export text clips, export images, database backup & restore
- Menu-bar tray with Ditto's original icon; recording can be paused (icon turns red, caption
  turns yellow — the "disconnected" state); launch at login; single instance
- UI language: 中文 / English, switchable in Settings without restart

## Keyboard map (same as Ditto)

| Key | Action |
|---|---|
| `Enter` / double-click | Paste |
| `⇧Enter` | Paste plain text |
| `⌥Enter` | Properties |
| `⌘1..0` | Paste items 1–10 |
| `Esc` | 3-level dismiss (tooltip → clear filter → close) |
| `⇧Esc` | Force close |
| `F3` / `N` / `P` | Full description / next / previous |
| `⌘C` `⌘A` | Copy selected / select all |
| `⌥C` | Clear filter |
| `⌃Space` | Toggle always-on-top |
| type anything | Jump into search |
| `Delete` | Delete entry |

## Build from source

```zsh
git clone <this repo> && cd ditto-mac
swift build -c release
./scripts/make-app.sh      # → DittoMac.app (arm64)
./scripts/make-dmg.sh      # → DittoMac-vX.Y.Z-arm64.dmg
./scripts/run-tests.sh     # 51 tests — Command Line Tools only
```

Releases are automated: push a tag (`v1.2.3`) and GitHub Actions runs the tests, builds and
attaches the DMG + tar.gz to the Release.

## Relationship to the original Ditto

- The original project: **[sabrogden/Ditto](https://github.com/sabrogden/Ditto)** — many
  thanks to Scott Brogden and all Ditto contributors for the best clipboard manager
  on Windows, maintained for two decades.
- DittoMac is an independent rewrite in Swift that follows Ditto's behavior and UI
  specification (extracted from its source code) to recreate the same experience natively on
  macOS. It shares no code with the original; the application icon is taken from the
  Ditto repository.
- Not ported (yet): LAN sync / friends, groups tree, per-entry hot keys, clip editor,
  QR codes, scripting.
- License: **GPL-3.0**, following Ditto. Not affiliated with or endorsed by the original
  project.

---

# 中文说明

**DittoMac 是开源 Windows 剪贴板管理器 [Ditto](https://github.com/sabrogden/Ditto) 的 Mac 版本**:
以 Swift/AppKit 从零原生重写,基于原版源码提取的行为规格开发,
目标只有一个——**让 Mac 用户获得与 Windows 版 Ditto 相同的使用体验**。

快速粘贴窗口、键盘映射、右键菜单、多格式剪贴板、去重置顶、粘贴回并恢复原剪贴板……
每一项行为都对照从原版源码提取的 38 条检查清单逐条复刻,并经 5 轮独立 QA 评分验证,
再以原生 macOS 风格呈现。

## 系统要求

- **macOS 13 (Ventura) 及以上,Apple Silicon (arm64) 芯片**
- 首次使用需授权"辅助功能"(模拟 ⌘V 所需,所有 Mac 剪贴板工具都一样)
- 零第三方依赖;构建只需 Command Line Tools,无需 Xcode

## 安装

```zsh
curl -fsSL https://raw.githubusercontent.com/<USER>/ditto-mac/main/scripts/install.sh | zsh
```

或从 [Releases](../../releases) 下载 DMG,拖入 Applications(首次打开如遇未公证提示:
右键 → 打开,或到 隐私与安全性 → "仍要打开")。

## 主要功能

- **自动记录剪贴板**:文本 / 富文本 / HTML / 图片 / 文件,单条目多格式并存,粘贴回原样恢复;
  相同内容重复复制时置顶旧记录;密码管理器内容自动跳过
- **快速粘贴面板**(`⌘⇧V`,可自定义):右侧竖排标题栏、前十条序号、置顶图钉、永不删除星标、
  已粘贴绿条、图片缩略图、颜色值色块、搜索高亮、相对时间;底部搜索框支持
  AND / OR / NOT / "引号短语" / `*` 通配;悬停条目即显示完整内容浮窗
- **粘贴回**:回车/双击 → 写入剪贴板 → 模拟 ⌘V 粘贴到光标处 → 0.4 秒后恢复原剪贴板;
  ⇧回车纯文本、多选拼接、多图合成;特殊粘贴子菜单 21 项(大小写/路径/换行/时间戳/
  Typoglycemia/Slugify/新 GUID/贴为图片……)与原版一致
- **管理**:条目顺序移动、置顶、永不自动删除、条目属性窗口、以此条过滤、导入导出、
  数据库备份/恢复、损坏自动重建;按条数/天数清理历史(受保护条目豁免)
- **托盘**:原版 Ditto 图标;暂停记录时图标变红、标题区变黄;开机自启;单实例
- **界面语言:中文 / English**,设置内即时切换,无需重启

## 从源码构建

```zsh
swift build -c release && ./scripts/make-app.sh && ./scripts/make-dmg.sh
./scripts/run-tests.sh   # 51 项测试
```

## 与原版的关系

- 原项目:**[sabrogden/Ditto](https://github.com/sabrogden/Ditto)**,感谢 Scott Brogden
  与所有贡献者二十年来的杰出工作
- DittoMac 是遵循其行为规格的独立 Swift 重写(不共享代码),应用图标取自原版仓库
- 暂未移植:局域网同步/好友、分组树、条目级热键、条目编辑器、二维码、脚本
- 许可证:**GPL-3.0**(跟随原版);与原项目无隶属关系
