#!/bin/zsh
# Builds and runs the PHAROS core Swift adapter tests (macOS, Swift 6).
set -euo pipefail
DIR="${0:A:h}"
OUT="${DIR}/../../.build/swift-adapter"
mkdir -p "${OUT}"
swiftc -parse-as-library -swift-version 6 \
  "${DIR}/PharosCoreAdapter.swift" "${DIR}/PharosCoreAdapterTests.swift" \
  -o "${OUT}/PharosCoreAdapterTests"
"${OUT}/PharosCoreAdapterTests"
