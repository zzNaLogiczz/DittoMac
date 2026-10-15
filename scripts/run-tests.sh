#!/bin/zsh
# 编译并运行 MiniTest 测试套(CLT 无 XCTest,单编译单元直连 DittoMacKit 源码)
# ⚠️ MonitorTests 会写入系统剪贴板:运行前请先退出正在运行的 DittoMac,否则样本会被正在运行的实例录进正式历史
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/build/mini-tests"
mkdir -p "${ROOT}/build"

swiftc -O \
  -o "${OUT}" \
  "${ROOT}"/Sources/DittoMacKit/*.swift \
  "${ROOT}/Sources/DittoMac/ClipDescription.swift" \
  "${ROOT}"/Tests/MiniTestShim/MiniTest.swift \
  "${ROOT}"/Tests/MiniTestShim/main.swift \
  "${ROOT}"/Tests/DittoMacKitTests/ClipStoreTests.swift \
  "${ROOT}"/Tests/DittoMacKitTests/MonitorAndPerfTests.swift \
  "${ROOT}"/Tests/DittoMacKitTests/SpecialPasteTests.swift \
  2>&1
STATUS=$?
if [ ${STATUS} -ne 0 ]; then echo "❌ 测试编译失败"; exit ${STATUS}; fi

"${OUT}"
exit $?
