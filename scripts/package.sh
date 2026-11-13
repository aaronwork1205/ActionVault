#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# ARCH=universal produces arm64 + x86_64; the default builds for this Mac.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
BUILD_ARGS=(-c release --disable-sandbox --cache-path "$PWD/.build/cache")
if [[ "${ARCH:-native}" == "universal" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
APP="dist/ActionVault.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
./scripts/build-icon.sh
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/ActionVault" "$APP/Contents/MacOS/ActionVault"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ActionVault</string>
<key>CFBundleIdentifier</key><string>local.actionvault.camera-backup</string>
<key>CFBundleName</key><string>ActionVault</string>
<key>CFBundleDisplayName</key><string>ActionVault</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.2</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSRemovableVolumesUsageDescription</key><string>读取相机素材，并在您确认后清理已验证备份的原文件。</string>
<key>NSNetworkVolumesUsageDescription</key><string>将相机素材备份到您选择的网络共享文件夹。</string>
</dict></plist>
PLIST
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/ActionVault.app"
ln -s /Applications "$STAGING/Applications"
cp README.md "$STAGING/使用说明.md"
hdiutil create -volname ActionVault -srcfolder "$STAGING" -ov -format UDZO dist/ActionVault.dmg
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit dist/ActionVault.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple dist/ActionVault.dmg
fi
printf 'Created %s/dist/ActionVault.dmg\n' "$PWD"
