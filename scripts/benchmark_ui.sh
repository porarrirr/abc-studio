#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
benchmark_dir="$(mktemp -d)"
trap 'rm -rf "$benchmark_dir"' EXIT
ln -s "$PWD/Sources/Fonts/Bravura.otf" "$benchmark_dir/Bravura.otf"
xcrun swiftc -O -whole-module-optimization Sources/ABC/ABCModel.swift \
    Sources/ABC/ABCParser.swift Sources/ABC/ABCBeaming.swift \
    Sources/Score/ScoreEngraver.swift Sources/SourceEditor.swift scripts/benchmark_ui.swift \
    -o "$benchmark_dir/benchmark-ui"
"$benchmark_dir/benchmark-ui"
