#!/bin/zsh
# Compile current settings UI against the debug Kit and render isolated fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-${ROOT}/build/settings-preview-images}"
WORK="${ROOT}/build/settings-preview"
PRODUCTS="${ROOT}/.build/debug"
mkdir -p "${WORK}" "${OUTPUT}"
if [[ ! -f "${PRODUCTS}/DittoMacKit.o" ]]; then
  echo 'Run swift build first.' >&2
  exit 1
fi
ditto "${PRODUCTS}/DittoMac_DittoMacKit.bundle" "${WORK}/DittoMac_DittoMacKit.bundle"
SOURCES=("${ROOT}"/Sources/DittoMac/*.swift)
SOURCES=("${(@)SOURCES:#*/main.swift}")
swiftc -I "${PRODUCTS}" "${SOURCES[@]}" \
  "${ROOT}/scripts/settings-preview/main.swift" "${PRODUCTS}/DittoMacKit.o" \
  -o "${WORK}/preview"
"${WORK}/preview" "${OUTPUT}" "${ROOT}"
