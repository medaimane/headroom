#!/bin/zsh
# Builds Headroom.app into ./build, signed ad hoc ("Sign to Run Locally") with the hardened runtime.
# Usage: scripts/make-app.sh [release|debug]
set -euo pipefail

config="${1:-release}"
root="${0:A:h:h}"
cd "$root"

swift build -c "$config" --product Headroom
bin="$(swift build -c "$config" --show-bin-path)"

app="build/Headroom.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Headroom" "$app/Contents/MacOS/Headroom"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - --options runtime --timestamp=none "$app"
codesign --verify --strict "$app"

echo "Built $root/$app ($config)"
