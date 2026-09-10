# PhoneLink 컨텍스트 노트

## 배경
Mac은 MTP를 지원하지 않아 안드로이드 폰이 Finder에 안 붙는다.
MacDroid는 File Provider 방식이라 파일을 미리 전부 복사해두어 느리고 디스크를 먹었다.
이미지 캡처(PTP)는 사진만 보여주고 폴더 정리가 안 된다.

## 채택한 방식
폰에 rclone 바이너리를 넣고 WebDAV 서버를 띄운 뒤,
adb forward로 USB 터널을 만들어 Finder가 WebDAV로 마운트한다.

측정치 (2026-09-10)
- 폴더 열기 169개 항목: 0.13초
- 폰으로 쓰기: 232 MB/s
- 사진 1장(4MB) 열기: 0.04초

## 결정과 이유

### 왜 WebDAV인가
Finder가 알아듣는 프로토콜은 FTP, WebDAV, SMB 뿐이다.
FTP는 macOS에서 읽기 전용이라 폴더 정리가 안 된다.
SMB 서버는 안드로이드에서 구현이 까다롭다.
WebDAV만 읽기/쓰기가 모두 되면서 구현이 간단하다.

### 왜 adb forward인가
Wi-Fi를 타면 느리고 폰 IP가 바뀌면 끊긴다.
adb forward는 USB로 터널을 뚫어 속도가 나오고 IP와 무관하다.
서버를 127.0.0.1에만 바인딩해서 같은 Wi-Fi의 다른 기기에 노출되지 않는다.

### 왜 rclone인가
폰에 앱을 설치하지 않고 바이너리 하나만 넣었다 빼면 된다.
정적 링크된 arm64 빌드라 의존성이 없다.
/data/local/tmp 에서 adb shell(uid 2000)로 실행 가능함을 확인했다.

### 왜 macFUSE를 안 쓰는가
Apple M5 + SIP 활성 환경에서 커널 확장을 쓰려면 보안 설정을 낮춰야 한다.
파일 브라우징 목적으로는 과한 대가다.

### 왜 Xcode 없이 빌드하는가
Command Line Tools의 swiftc 6.3.1과 macOS 26 SDK로 AppKit 앱을 빌드할 수 있다.
Xcode 전체(수십 GB) 설치가 불필요하다.

## 알려진 제약
- 폰 화면이 잠겨 있으면 안드로이드가 저장소를 노출하지 않는다.
- Finder 사이드바 이름이 마운트 주소로 표시된다.
- 서버 프로세스는 USB를 뽑거나 폰을 재부팅하면 죽는다. 앱이 재시작한다.
- rclone 바이너리는 /data/local/tmp 에 남는다. 재부팅해도 유지된다.

## 앱 구현 (2026-09-10)

### 구조
Swift + AppKit 메뉴바 앱. Xcode 없이 Command Line Tools swiftc 6.3.1로 빌드한다.
`build.sh` 하나로 컴파일, 번들 생성, rclone 동봉, 임시 서명까지 끝난다.

### 셸 스크립트와의 차이
`~/bin/phone.sh` 는 그대로 두었다. 앱이 안 될 때 쓸 수 있는 대비책이다.
앱은 스크립트에 없던 것을 추가했다.
- 잠금 화면 감지 후 안내
- rclone이 폰에 없으면 앱 번들에서 자동 배포
- 꽂으면 자동 연결
- 앱 종료 시 자동 정리

### 미검증 변경 하나
Finder 볼륨 이름이 `127.0.0.1` 로 뜨는 게 보기 싫어서
rclone의 `--baseurl /PhoneLink` 를 붙이고 그 주소로 마운트하도록 했다.
macOS가 WebDAV 볼륨 이름을 URL 마지막 경로에서 따온다는 가정인데 아직 확인하지 못했다.
폰 연결 후 확인이 필요하다. 안 되면 baseurl을 빼고 `/Volumes/127.0.0.1` 로 되돌린다.

### 왜 폴링인가
USB 연결 감지에 IOKit 알림을 쓰면 코드가 늘어난다.
3초 폴링으로 충분히 반응이 빠르고 CPU도 거의 안 쓴다.
