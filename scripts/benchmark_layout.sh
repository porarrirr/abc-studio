#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
benchmark_dir="$(mktemp -d)"
trap 'rm -rf "$benchmark_dir"' EXIT
xcrun swiftc -O -whole-module-optimization Sources/ABC/ABCModel.swift \
    Sources/ABC/ABCParser.swift Sources/ABC/ABCBeaming.swift \
    Sources/Score/ScoreEngraver.swift scripts/benchmark_layout.swift \
    -o "$benchmark_dir/benchmark-layout"
"$benchmark_dir/benchmark-layout"
