#!/bin/zsh
# DittoMac.app → 可安装 DMG(拖拽安装:窗口内含 Applications 软链接,图标布局定制)
# 版本号:DITTOMAC_VERSION(默认 1.0.0;CI 传 git tag)
# DITTOMAC_DMG_LAYOUT=0:直接创建只读镜像,不打开 Finder 或操作桌面。
#
# 流程:读写镜像(UDRW)→ 挂载 → Finder 设图标位置 → 卸载 → 压缩(UDZO)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/DittoMac.app"
VERSION="${DITTOMAC_VERSION:-1.0.0}"
VERSION="${VERSION#v}"
VOLNAME="DittoMac"
OUT="${ROOT}/DittoMac-${VERSION}-arm64.dmg"
RW_DMG="$(mktemp -d)/rw.dmg"
MNT="$(mktemp -d)"

if [[ ! -d "${APP}" ]]; then
  echo "未找到 ${APP},先执行:swift build -c release && ./scripts/make-app.sh" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}" "${RW_DMG}" "${MNT}"' EXIT

# 舞台:App + 指向 /Applications 的软链接(拖拽安装动线)
cp -R "${APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
rm -f "${OUT}"

if [[ "${DITTOMAC_DMG_LAYOUT:-1}" == "0" ]]; then
  hdiutil create -volname "${VOLNAME} ${VERSION}" \
    -srcfolder "${STAGING}" -fs HFS+ -format UDZO -ov -quiet "${OUT}"
  echo "✅ 已生成 ${OUT}"
  shasum -a 256 "${OUT}"
  exit 0
fi

# 1) 读写镜像
hdiutil create -volname "${VOLNAME}" \
  -srcfolder "${STAGING}" \
  -fs HFS+ -format UDRW -ov -quiet "${RW_DMG}"

# 2) 挂载并美化(必须挂到 /Volumes,Finder 只管理那里的卷;只读压缩格式改不了图标位置)
hdiutil attach "${RW_DMG}" -quiet   # 挂载到 /Volumes/${VOLNAME}
osascript <<OSA 2>/dev/null || echo "(提示:Finder 自动化不可用,DMG 使用默认图标布局)"
tell application "Finder"
  tell disk "${VOLNAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 720, 460}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set position of item "DittoMac.app" of container window to {140, 160}
    set position of item "Applications" of container window to {380, 160}
    close
    open
    update without registering applications
  end tell
end tell
OSA
sleep 1   # 等 Finder 把 .DS_Store 落盘
hdiutil detach "/Volumes/${VOLNAME}" -quiet

# 3) 压缩成品(convert 会自动追加 .dmg 后缀)
TMP_BASE="${OUT%.dmg}.layout"
hdiutil convert "${RW_DMG}" -format UDZO -ov -quiet -o "${TMP_BASE}" >/dev/null
mv "${TMP_BASE}.dmg" "${OUT}"

echo "✅ 已生成 ${OUT}"
shasum -a 256 "${OUT}" | awk '{print "SHA256:", $1}'
