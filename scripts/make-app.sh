#!/bin/zsh
# 把 swift build 的产物打包成 DittoMac.app(arm64 原生)
# 版本号:DITTOMAC_VERSION 环境变量(默认 1.0.0;CI 上传 git tag 名)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${ROOT}/.build/release/DittoMac"
RESOURCE_BUNDLE="${ROOT}/.build/release/DittoMac_DittoMacKit.bundle"
APP="${ROOT}/DittoMac.app"
VERSION="${DITTOMAC_VERSION:-1.0.0}"
VERSION="${VERSION#v}"   # 允许传 v1.2.3

if [[ ! -x "${BIN}" ]]; then
  echo "未找到 ${BIN},先执行:swift build -c release" >&2
  exit 1
fi
if [[ ! -d "${RESOURCE_BUNDLE}" ]]; then
  echo "未找到资源包 ${RESOURCE_BUNDLE},请重新执行:swift build -c release" >&2
  exit 1
fi

# 系统按二进制记录的 SDK 版本决定界面行为:记录成旧版本时整个 App 走旧版兼容外观。
# 部分 SwiftPM 版本链接时不传 -isysroot,clang 读不到 SDK 版本,会把部署目标(13.0)写进去。
SDK_EXPECTED="$(xcrun --sdk macosx --show-sdk-version)"
SDK_STAMPED="$(otool -l "${BIN}" | awk '/LC_BUILD_VERSION/{f=1} f && $1 == "sdk" && !v {v=$2} END{print v}')"
if [[ "${SDK_STAMPED%%.*}" != "${SDK_EXPECTED%%.*}" ]]; then
  echo "二进制记录的 SDK 版本是 ${SDK_STAMPED:-未知},当前 SDK 是 ${SDK_EXPECTED},App 会使用旧版系统外观。请重新构建:" >&2
  echo '  swift build -c release -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$(xcrun --sdk macosx --show-sdk-path)"' >&2
  exit 1
fi

# 每次打包都从新版源图生成图标，避免沿用旧 ICNS。
zsh "${ROOT}/scripts/make-icon.sh"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/DittoMac"
# Bundle.module 在正式 App 内从 Contents/Resources 查找 SwiftPM 资源包。
ditto "${RESOURCE_BUNDLE}" "${APP}/Contents/Resources/DittoMac_DittoMacKit.bundle"

# macOS 版应用图标（基于原版 Ditto 标识重新设计，GPL-3.0）
ICON_SRC="${ROOT}/Resources/AppIcon.icns"
cp "${ICON_SRC}" "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DittoMac</string>
    <key>CFBundleDisplayName</key>
    <string>DittoMac</string>
    <key>CFBundleIdentifier</key>
    <string>local.dittomac.app</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>DittoMac</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>GPL-3.0 · 基于 Ditto (sabrogden/Ditto) 的规格重写</string>
</dict>
</plist>
PLIST

# 优先用稳定自签名证书"DittoMac Dev"签名(TCC 授权跨构建持久);
# 证书不存在时回退 ad-hoc(每次重装需重授辅助功能权限)
SIGN_ID="DittoMac Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --identifier local.dittomac.app "${APP}" && echo "已用 $SIGN_ID 签名"
else
  codesign --force --sign - --identifier local.dittomac.app "${APP}" 2>/dev/null && echo "已用 ad-hoc 签名"
fi

echo "✅ 已生成 ${APP}"
file "${APP}/Contents/MacOS/DittoMac"
