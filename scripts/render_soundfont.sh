#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
render_workspace=$(mktemp -d /tmp/abc-soundfont-render.XXXXXX)
trap 'rm -rf "$render_workspace"' EXIT
cat "$script_dir/../Sources/Audio/Instruments.swift" "$script_dir/render_soundfont.swift" > "$render_workspace/main.swift"
swiftc -O "$render_workspace/main.swift" -o "$render_workspace/render"
"$render_workspace/render" "$@"
