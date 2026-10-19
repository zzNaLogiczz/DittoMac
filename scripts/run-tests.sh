#!/bin/zsh
# 编译并运行 MiniTest 测试套(CLT 无 XCTest,单编译单元直连 DittoMacKit 源码)
# ⚠️ MonitorTests 会写入系统剪贴板:运行前请先退出正在运行的 DittoMac,否则样本会被正在运行的实例录进正式历史
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--noninteractive" ]]; then
  shift
  exec python3 "${ROOT}/scripts/run-noninteractive-tests.py" "$@"
fi
if (( $# > 0 )); then
  echo "Usage: $0 [--noninteractive [--output-dir PATH]]" >&2
  exit 2
fi
OUT="${ROOT}/build/mini-tests"
mkdir -p "${ROOT}/build"

# -D DITTO_NO_SPM_RESOURCES:直连编译无 Bundle.module,DittoThemeFile 里的
# 内置主题目录回退 #filePath 源码树路径(与 SPM 构建产物双轨)
swiftc -O \
  -D DITTO_NO_SPM_RESOURCES \
  -o "${OUT}" \
  "${ROOT}"/Sources/DittoMacKit/*.swift \
  "${ROOT}/Sources/DittoMac/ClipDescription.swift" \
  "${ROOT}/Sources/DittoMac/L10n.swift" \
  "${ROOT}"/Tests/MiniTestShim/MiniTest.swift \
  "${ROOT}"/Tests/MiniTestShim/main.swift \
  "${ROOT}"/Tests/DittoMacKitTests/*.swift \
  2>&1
STATUS=$?
if [ ${STATUS} -ne 0 ]; then echo "❌ 测试编译失败"; exit ${STATUS}; fi

"${OUT}"
exit $?
