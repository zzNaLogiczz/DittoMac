#!/bin/zsh
# 从 macOS 版图标源图生成包含标准及 Retina 尺寸的 ICNS。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${ROOT}/Resources/icon-macos.png"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
ICONSET="${WORK_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET}"

for SIZE in 16 32 128 256 512; do
  sips -z "${SIZE}" "${SIZE}" "${SOURCE}" --out "${ICONSET}/icon_${SIZE}x${SIZE}.png" >/dev/null
  RETINA_SIZE=$((SIZE * 2))
  sips -z "${RETINA_SIZE}" "${RETINA_SIZE}" "${SOURCE}" --out "${ICONSET}/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

iconutil -c icns "${ICONSET}" -o "${WORK_DIR}/AppIcon.icns"
mv "${WORK_DIR}/AppIcon.icns" "${ROOT}/Resources/AppIcon.icns"
echo "已生成 Resources/AppIcon.icns"
