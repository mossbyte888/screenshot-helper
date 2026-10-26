#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

app_name='截图助手.app'
if [[ ! -d "$app_name" ]]; then
    echo '请先运行 bash build.sh，生成截图助手.app。' >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_name/Contents/Info.plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "无法打包：应用版本号格式不正确：$version" >&2
    exit 1
fi

dmg_temp=$(mktemp -d)
trap 'rm -rf "$dmg_temp"' EXIT
staging="$dmg_temp/package"
mkdir -p "$staging" release-assets

# Preserve the existing binary and signature; omit Finder resource metadata.
ditto --norsrc "$app_name" "$staging/$app_name"
xattr -dr com.apple.FinderInfo "$staging/$app_name" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$staging/$app_name" 2>/dev/null || true
codesign --verify --strict "$staging/$app_name"
ln -s /Applications "$staging/Applications"
cp LICENSE "$staging/LICENSE.txt"
cat > "$staging/安装说明.txt" <<EOF
截图助手 ${version}

安装方法
1. 将“截图助手.app”拖到本窗口中的“Applications”（应用程序）文件夹。
2. 等待复制完成，从“应用程序”中打开“截图助手”。
3. 安装完成后，可在访达边栏推出“截图助手 ${version}”磁盘。

更新已有版本时，请先从菜单栏退出截图助手，再复制并替换。

系统要求：Apple Silicon Mac（M 系列芯片），macOS 13 或更新版本。
首次截图时，请在系统设置的隐私与安全性中允许屏幕录制权限。
本版本使用本地签名，尚未进行 Apple Developer ID 签名或公证。
如果 macOS 阻止打开，请查看项目 README 的安装说明。

源码与使用说明：https://github.com/mossbyte888/screenshot-helper
许可证：MIT，详见 LICENSE.txt。
EOF

filename="ScreenshotHelper-$version-macOS-arm64.dmg"
hdiutil create -volname "截图助手 $version" -fs HFS+ \
    -srcfolder "$staging" -format UDZO -imagekey zlib-level=9 \
    "$dmg_temp/$filename"
hdiutil verify "$dmg_temp/$filename"
mv "$dmg_temp/$filename" "release-assets/$filename"
(
    cd release-assets
    shasum -a 256 "$filename" > "$filename.sha256.txt"
)
echo "Built: $PWD/release-assets/$filename"
