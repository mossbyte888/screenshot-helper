#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_temp=$(mktemp -d)
trap 'rm -rf "$build_temp"' EXIT
app="$build_temp/截图助手.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
extra_args=()
toolchain_include="$(xcrun --find swiftc | sed 's@/bin/swiftc$@/include/swift@')"
if [[ -f "$toolchain_include/module.modulemap" && -f "$toolchain_include/bridging.modulemap" ]]; then
    # Some Command Line Tools upgrades leave a duplicate legacy SwiftBridging module.
    # Hide that legacy declaration only inside the compiler's virtual filesystem.
    touch "$build_temp/empty.modulemap"
    python3 - "$toolchain_include/module.modulemap" "$build_temp" <<'PY'
import json, pathlib, sys
source, root = sys.argv[1:]
pathlib.Path(root, 'overlay.json').write_text(json.dumps({'version': 0, 'roots': [
    {'type': 'file', 'name': source, 'external-contents': str(pathlib.Path(root, 'empty.modulemap'))}
]}))
PY
    extra_args=(-vfsoverlay "$build_temp/overlay.json" -Xcc -ivfsoverlay -Xcc "$build_temp/overlay.json")
fi
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
    -framework AppKit -framework Carbon -framework CoreGraphics \
    "${extra_args[@]}" main.swift -o "$app/Contents/MacOS/ScreenshotHelper"
cp Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto --norsrc -c -k --keepParent "$app" '截图助手.zip'
ditto --norsrc "$app" '截图助手.app'
echo "Built: $PWD/截图助手.app and 截图助手.zip"
