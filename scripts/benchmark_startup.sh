#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
benchmark_dir="$(mktemp -d)"
trap 'rm -rf "$benchmark_dir"' EXIT
ln -s "$PWD/SoundFont" "$benchmark_dir/SoundFont"
ln -s "$PWD/Sources/Audio/HRTF/HeadphoneHRTF.json" "$benchmark_dir/HeadphoneHRTF.json"
xcrun swiftc -O -whole-module-optimization Sources/ABC/ABCModel.swift Sources/ABC/ABCParser.swift \
    Sources/ABC/ABCBeaming.swift Sources/Audio/ABCSequencer.swift Sources/Audio/Instruments.swift \
    Sources/Audio/OrchestraSpatializer.swift Sources/Audio/HeadphoneRendering.swift \
    "${4:-Sources/Audio/SoundFontPlayer.swift}" "${2:-Sources/Audio/PlaybackEngine.swift}" \
    scripts/benchmark_startup.swift -o "$benchmark_dir/benchmark-startup"
"$benchmark_dir/benchmark-startup" "$1" "${3:-0}"
