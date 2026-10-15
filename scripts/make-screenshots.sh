#!/bin/zsh
# Render the real AppKit panel at 3× with isolated, bilingual demo data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
swiftc -emit-library -emit-module -module-name DittoMacKit \
  "${ROOT}"/Sources/DittoMacKit/*.swift \
  -emit-module-path "${WORK_DIR}/DittoMacKit.swiftmodule" \
  -o "${WORK_DIR}/libDittoMacKit.dylib"
APP_SOURCES=("${ROOT}"/Sources/DittoMac/*.swift)
APP_SOURCES=("${(@)APP_SOURCES:#*/main.swift}")
swiftc -I "${WORK_DIR}" -L "${WORK_DIR}" -lDittoMacKit \
  -Xlinker -rpath -Xlinker "${WORK_DIR}" \
  "${APP_SOURCES[@]}" "${ROOT}/scripts/screenshots/main.swift" \
  -o "${WORK_DIR}/ditto-screenshots"
for SCREENSHOT_LANG in en zh; do
  "${WORK_DIR}/ditto-screenshots" "${SCREENSHOT_LANG}" "${ROOT}/screenshots/panel-${SCREENSHOT_LANG}.png"
done
