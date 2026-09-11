#!/bin/bash
# ADBDAV.app 을 빌드한다. Xcode 없이 Command Line Tools 의 swiftc 만 사용한다.
set -euo pipefail

cd "$(dirname "$0")"
APP="ADBDAV.app"

# 1. 번들 구조 생성
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 2. 컴파일
echo "컴파일 중..."
swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -o "$APP/Contents/MacOS/ADBDAV" \
  Sources/main.swift

# 4. 아이콘과 메뉴바 이미지
cp Resources/ADBDAV.icns "$APP/Contents/Resources/"
cp Resources/bar_*.png "$APP/Contents/Resources/"

# 5. Info.plist
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ADBDAV</string>
  <key>CFBundleDisplayName</key><string>ADBDAV</string>
  <key>CFBundleIdentifier</key><string>local.adbdav</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>ADBDAV</string>
  <key>CFBundleIconFile</key><string>ADBDAV</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>폰의 파일을 Finder에서 열기 위해 필요합니다.</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 6. 임시 서명 (서명이 없으면 실행이 막힌다)
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "빌드 완료: $(pwd)/$APP"
