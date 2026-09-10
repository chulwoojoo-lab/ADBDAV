#!/bin/bash
# PhoneLink.app 을 빌드한다. Xcode 없이 Command Line Tools 의 swiftc 만 사용한다.
set -euo pipefail

cd "$(dirname "$0")"
APP="PhoneLink.app"
VENDOR="vendor/rclone-arm64"

# 1. 폰에 넣을 rclone(리눅스 arm64) 준비
if [ ! -f "$VENDOR" ]; then
  echo "rclone 내려받는 중..."
  mkdir -p vendor tmp
  curl -sL -o tmp/rclone.zip https://downloads.rclone.org/rclone-current-linux-arm64.zip
  unzip -oq tmp/rclone.zip -d tmp
  find tmp -name rclone -type f -exec cp {} "$VENDOR" \;
  chmod +x "$VENDOR"
  rm -rf tmp
fi

# 2. 번들 구조 생성
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 3. 컴파일
echo "컴파일 중..."
swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -o "$APP/Contents/MacOS/PhoneLink" \
  Sources/main.swift

# 4. 리소스와 Info.plist
cp "$VENDOR" "$APP/Contents/Resources/rclone-arm64"
chmod +x "$APP/Contents/Resources/rclone-arm64"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PhoneLink</string>
  <key>CFBundleDisplayName</key><string>PhoneLink</string>
  <key>CFBundleIdentifier</key><string>local.phonelink</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>PhoneLink</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 5. 임시 서명 (서명이 없으면 실행이 막힌다)
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "빌드 완료: $(pwd)/$APP"
