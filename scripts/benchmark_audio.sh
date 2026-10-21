#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
benchmark_dir="$(mktemp -d)"
trap 'rm -rf "$benchmark_dir"' EXIT
ln -s "$PWD/SoundFont" "$benchmark_dir/SoundFont"
xcrun swiftc -O -whole-module-optimization "${1:-Sources/Audio/SoundFontPlayer.swift}" \
    scripts/benchmark_audio.swift -o "$benchmark_dir/benchmark-audio"
"$benchmark_dir/benchmark-audio"
