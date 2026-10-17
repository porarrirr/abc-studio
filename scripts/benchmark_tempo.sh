#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
benchmark_dir="$(mktemp -d)"
trap 'rm -rf "$benchmark_dir"' EXIT
xcrun swiftc -O -whole-module-optimization Sources/ABC/ABCModel.swift Sources/ABC/ABCParser.swift \
    "${1:-Sources/Audio/ABCSequencer.swift}" scripts/benchmark_tempo.swift \
    -o "$benchmark_dir/benchmark-tempo"
"$benchmark_dir/benchmark-tempo"
