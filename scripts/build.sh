#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/VM Re-Sizer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Development"
for ARCH in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -parse-as-library -O -target "$ARCH-apple-macosx13.0" \
    Sources/UpdateCore.swift Sources/VMUpdater.swift -o "$OUT/VMUpdater-$ARCH"
  xcrun swiftc -swift-version 5 -parse-as-library -O -target "$ARCH-apple-macosx13.0" \
    Sources/UpdateCore.swift Sources/UpdateController.swift Sources/VMReSizer.swift -o "$OUT/VMReSizer-$ARCH"
done
xcrun lipo -create "$OUT/VMUpdater-arm64" "$OUT/VMUpdater-x86_64" -output "$APP/Contents/Helpers/VMUpdater"
xcrun lipo -create "$OUT/VMReSizer-arm64" "$OUT/VMReSizer-x86_64" -output "$APP/Contents/MacOS/VMReSizer"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Sources scripts Tests Info.plist AppIcon.icns README.md RELEASE_NOTES.md "$APP/Contents/Resources/Development/"
codesign --force --sign - "$APP/Contents/Helpers/VMUpdater"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
# No resource forks or __MACOSX entries: the updater permits only this app bundle.
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUT/VM-Re-Sizer-macOS.zip"
(cd "$OUT" && shasum -a 256 VM-Re-Sizer-macOS.zip > SHA256SUMS)
printf 'Built %s\n' "$APP"
