#!/bin/bash
# 배포용 .dmg 를 만든다. 사용자가 받아서 응용 프로그램으로 끌어다 놓는 방식이다.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?사용법: ./release.sh 1.0.0}"
APP="ADBDAV.app"
DMG="dist/ADBDAV-$VERSION.dmg"
STAGE="dist/stage"

./build.sh

rm -rf dist && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # 끌어다 놓을 대상

hdiutil create -volname "ADBDAV" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "만들어짐: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG" | awk '{print "SHA-256: "$1}'
