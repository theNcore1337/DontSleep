#!/usr/bin/env bash
# Builds openeye.app from main.swift — no Xcode GUI required.
set -euo pipefail

APP_NAME="openeye"
BUNDLE_ID="com.theNcore.openeye"
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
ASSETS="$DIR/assets"

echo "==> Generating icons"
ICONGEN="$(mktemp -d)/icongen"
xcrun swiftc -O -framework AppKit -framework CoreImage -o "$ICONGEN" "$DIR/IconGenerator.swift"
rm -rf "$ASSETS"; mkdir -p "$ASSETS"
"$ICONGEN" "$ASSETS"

echo "==> Building AppIcon.icns (OFF variant = default bundle icon)"
ICONSET="$ASSETS/AppIcon.iconset"
mkdir -p "$ICONSET"
M="$ASSETS/icon_off_1024.png"
sips -z 16   16   "$M" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32   32   "$M" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$M" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64   64   "$M" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$M" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$M" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$M" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$M" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$M" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$M"            "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$ASSETS/AppIcon.icns"

echo "==> Building runtime Dock-icon variants (512)"
sips -z 512 512 "$ASSETS/icon_off_1024.png" --out "$ASSETS/AppIconOff.png" >/dev/null
sips -z 512 512 "$ASSETS/icon_on_1024.png"  --out "$ASSETS/AppIconOn.png"  >/dev/null

echo "==> Cleaning bundle"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "==> Compiling"
xcrun swiftc -O \
  -target arm64-apple-macos26.0 \
  -framework SwiftUI -framework AppKit \
  -o "$MACOS/$APP_NAME" \
  "$DIR/main.swift"

echo "==> Copying resources"
cp "$ASSETS/AppIcon.icns" "$RES/AppIcon.icns"
cp "$ASSETS/AppIconOn.png" "$ASSETS/AppIconOff.png" "$RES/"

echo "==> Copying localizations"
for lang in en ru; do
  mkdir -p "$RES/$lang.lproj"
  cp "$DIR/$lang.lproj/Localizable.strings" "$RES/$lang.lproj/Localizable.strings"
done

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>ru</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "==> Writing PkgInfo"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --sign - "$APP"

echo "==> Done: $APP"
