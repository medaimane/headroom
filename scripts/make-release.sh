#!/bin/zsh
# Builds a downloadable release: a universal (Apple silicon + Intel) Headroom.app,
# signed ad hoc with the hardened runtime, zipped for a GitHub release.
#
# Output (in ./build):
#   Headroom.zip          the file the website's Download button points at
#   Headroom.zip.sha256   its checksum, to paste into the release notes
#
# The app is not notarized (that needs a paid Apple Developer account), so on
# other Macs Gatekeeper asks the user to approve it once. See the guide's
# "Download" section.
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
archs=(--arch arm64 --arch x86_64)

# The website and changelog must describe this version before it ships.
for page in docs/index.html docs/guide/index.html; do
  if ! grep -q "data-version=\"$version\"" "$page"; then
    echo "error: $page doesn't show version $version (update its data-version label)" >&2; exit 1
  fi
done
if ! grep -q "^## \[$version\]" CHANGELOG.md; then
  echo "error: CHANGELOG.md has no section for $version" >&2; exit 1
fi

swift build -c release "${archs[@]}" --product Headroom
bin="$(swift build -c release "${archs[@]}" --show-bin-path)"

app="build/release/Headroom.app"
rm -rf build/release
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Headroom" "$app/Contents/MacOS/Headroom"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - --options runtime --timestamp=none "$app"
codesign --verify --strict "$app"

zip="build/Headroom.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
(cd build && shasum -a 256 Headroom.zip > Headroom.zip.sha256)

echo "Headroom $version for $(lipo -archs "$app/Contents/MacOS/Headroom")"
echo "Wrote $root/$zip"
cat build/Headroom.zip.sha256
