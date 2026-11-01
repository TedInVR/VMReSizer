#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -swift-version 5 -parse-as-library -D TESTING \
  Sources/UpdateCore.swift Sources/UpdateController.swift Sources/VMUpdater.swift Sources/VMReSizer.swift \
  Tests/Tests.swift -o build/VMReSizerTests
build/VMReSizerTests
