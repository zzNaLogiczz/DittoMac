#!/bin/zsh
# DittoMac 一键安装:从 GitHub Releases 下载最新版并安装到 /Applications。
# 通过 curl 流式解压,文件不带 quarantine 属性 → 无 Gatekeeper 拦截,装完即用。
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/<USER>/ditto-mac/main/scripts/install.sh | zsh
#
# 可选环境变量:
#   DITTOMAC_REPO=<user>/<repo>   (默认自动从脚本 URL 推断,或用此变量指定)

set -euo pipefail

REPO="${DITTOMAC_REPO:-}"
APP_NAME="DittoMac.app"

# 从脚本自身 URL 推断仓库(支持 raw.githubusercontent.com 链接)
if [[ -z "$REPO" ]]; then
  SCRIPT_URL="${(%):-%x}" 2>/dev/null || SCRIPT_URL=""
  case "$SCRIPT_URL" in
    *raw.githubusercontent.com*) REPO="${SCRIPT_URL#*raw.githubusercontent.com/}"; REPO="${REPO%%/scripts/*}" ;;
    *) REPO="" ;;
  esac
fi
if [[ -z "$REPO" ]]; then
  echo "❌ 无法确定 GitHub 仓库,请用:DITTOMAC_REPO=<user>/<repo> bash <(curl -fsSL <install.sh URL>)"
  exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  echo "⚠️ 当前版本仅提供 Apple Silicon(arm64)构建,检测到 $ARCH"
fi

echo "==> 查询最新版本($REPO)…"
API="https://api.github.com/repos/$REPO/releases/latest"
# 按文件名取 tar.gz:Release 里还有 DMG 和校验文件,附件顺序不固定
TARBALL_URL="$(curl -fsSL "$API" | /usr/bin/python3 -c 'import json,sys; print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith("-arm64.tar.gz")))')"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 下载 $TARBALL_URL …"
curl -fL --progress-bar "$TARBALL_URL" -o "$WORK/dittomac.tar.gz"

echo "==> 解压…"
tar -xzf "$WORK/dittomac.tar.gz" -C "$WORK"

echo "==> 关闭正在运行的实例…"
pkill -x DittoMac 2>/dev/null && sleep 1 || true

echo "==> 安装到 /Applications…"
rm -rf "/Applications/$APP_NAME"
cp -R "$WORK/$APP_NAME" /Applications/
# 双保险:清除可能存在的隔离属性(手动下载的包经 AirDrop/浏览器中转时可能带上)
xattr -dr com.apple.quarantine "/Applications/$APP_NAME" 2>/dev/null || true

echo "==> 启动…"
open "/Applications/$APP_NAME"

cat <<'NOTE'

✅ DittoMac 已安装并启动!

首次使用请授权"辅助功能"(粘贴回原位置需要):
  系统设置 → 隐私与安全性 → 辅助功能(设备控制和数据访问)→ 打开 DittoMac 开关

快捷键:⌘⇧V 打开面板 · Enter/双击 粘贴 · ⇧Enter 纯文本 · Esc 关闭
NOTE
