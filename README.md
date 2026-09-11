# ABDAV

안드로이드 폰을 USB로 Finder에 드라이브처럼 붙여주는 메뉴바 앱.

## 쓰는 법
1. `ABDAV.app` 실행. 메뉴바에 아이폰 모양 아이콘이 생긴다.
2. 폰을 USB로 연결하고 화면 잠금을 푼다.
3. 자동으로 Finder에 마운트된다. 아이콘을 눌러 수동으로 해도 된다.

## 필요한 것
- 폰의 USB 디버깅 켜짐
- `adb` 설치 (`brew install android-platform-tools`)

## 다시 빌드
```
./build.sh
```

## 원리
폰에 rclone을 넣어 WebDAV 서버를 띄우고, adb forward로 USB 터널을 만들어
Finder가 그 서버를 마운트한다. Wi-Fi를 쓰지 않아 USB 속도가 나온다.
서버는 폰 내부(127.0.0.1)에만 열려 다른 기기에서 보이지 않는다.

## 폰에서 지우려면
```
adb shell rm -f /data/local/tmp/rclone /data/local/tmp/rclone.log
```
