// 안드로이드 폰을 USB 또는 Wi-Fi(adb)로 WebDAV 마운트해 Finder에 연결하는 메뉴바 앱

import AppKit
import ServiceManagement


// MARK: - 표시 언어

/// 화면에 보이는 문구의 언어. system 이면 macOS 설정을 따른다.
enum Lang: String, CaseIterable {
    case system, en, ko

    var resolved: Lang {
        guard self == .system else { return self }
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.hasPrefix("ko") ? .ko : .en
    }

    var label: String {
        switch self {
        case .system: return T.s("System", "시스템 설정")
        case .en:     return "English"
        case .ko:     return "한국어"
        }
    }
}

/// 문구를 영어와 한국어로 나란히 적는다.
/// 별도 키 표를 두지 않아 번역 누락이 생기지 않는다.
enum T {
    static var lang: Lang = .system
    static func s(_ en: String, _ ko: String) -> String {
        lang.resolved == .ko ? ko : en
    }
}

// MARK: - 설정

enum Config {
    static let port = 8090
    static let baseURL = "ADBDAV"          // Finder 볼륨 이름이 된다
    static let remoteBinary = "/data/local/tmp/rclone"
    static let remoteLog = "/data/local/tmp/rclone.log"
    static let sharedPath = "/sdcard"
    /// 건강 확인용. 언제나 되는 주소를 쓴다.
    static var healthURL: String { "http://127.0.0.1:\(port)/" }

    /// Finder 사이드바의 이름표는 마운트 주소의 호스트 이름을 그대로 따라간다.
    /// 127.0.0.1 로 붙이면 사이드바에 숫자가 뜨므로 이름이 있는 주소를 먼저 쓴다.
    /// `*.localhost` 는 어느 Mac 에서나 설정 없이 127.0.0.1 로 풀린다.
    /// 접미사 없이 ABDAV 로만 띄우려면 /etc/hosts 를 고쳐야 하는데,
    /// 쓰는 사람마다 시스템 파일을 건드리게 할 수는 없어서 쓰지 않는다.
    static let hostCandidates = ["ADBDAV.localhost", "127.0.0.1"]

    static func mountURL(host: String) -> String {
        "http://\(host):\(port)/"
    }

    /// 마운트 지점. 이 폴더 이름이 그대로 Finder 볼륨 이름이 된다.
    /// AppleScript 의 mount volume 을 쓰면 Finder 가 127.0.0.1 이라는 서버 항목 아래
    /// 공유를 넣어 두 단계가 된다. 홈 폴더에 직접 마운트하면 볼륨 하나로 바로 보인다.
    static var mountDir: String { NSHomeDirectory() + "/" + baseURL }
}

/// 폰에 닿는 경로. 같은 adb를 쓰지만 USB 쪽이 30배 이상 빠르다.
enum TransportMode: String {
    case usb
    case wifi

    var label: String { self == .usb ? "USB" : "Wi-Fi" }
}


// MARK: - 진단 로그

enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/ADBDAV.log"
    static func write(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - 셸 실행

struct Shell {
    struct Result {
        let code: Int32
        let out: String
        var ok: Bool { code == 0 }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> Result {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Result(code: 127, out: T.s("Executable not found: \(path)", "실행 파일 없음: \(path)"))
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do { try task.run() } catch {
            return Result(code: 126, out: T.s("Failed to run: \(error.localizedDescription)", "실행 실패: \(error.localizedDescription)"))
        }

        let deadline = Date().addingTimeInterval(timeout)
        let handle = pipe.fileHandleForReading
        let box = DataBox()

        DispatchQueue.global().async {
            box.set(handle.readDataToEndOfFile())
        }

        while task.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if task.isRunning {
            task.terminate()
            return Result(code: 124, out: T.s("Timed out", "시간 초과"))
        }
        task.waitUntilExit()
        usleep(120_000)  // 파이프 읽기 마무리 대기
        let text = String(data: box.get(), encoding: .utf8) ?? ""
        return Result(code: task.terminationStatus, out: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// 다른 큐에서 읽은 출력을 안전하게 주고받기 위한 상자
final class DataBox {
    private var data = Data()
    private let lock = NSLock()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}


// MARK: - 폰에 넣을 rclone

/// 폰에서 WebDAV 서버 노릇을 할 바이너리. 버전을 박아둔다.
///
/// 최신을 따라가면 rclone 이 뭔가 바꿨을 때 우리가 손을 놓은 사이
/// 모든 사용자가 동시에 깨진다. 고정해두면 이 프로젝트가 멈춰도
/// 같은 파일이 계속 받아져 그대로 동작한다.
/// 우리가 쓰는 `serve webdav` 는 오래된 기본 기능이라 최신일 이유가 없다.
///
/// 올리고 싶으면 아래 두 줄만 바꾸면 된다.
/// 체크섬은 https://downloads.rclone.org/<version>/SHA256SUMS 에 공개돼 있다.
enum RClone {
    static let version = "v1.75.1"
    static let sha256 = "03f2504174034b6d004152ed7369251c9a9ec1f7e0836eda420f5c7a5ec0dff9"

    static var zipName: String { "rclone-\(version)-linux-arm64.zip" }
    static var url: String { "https://downloads.rclone.org/\(version)/\(zipName)" }

    static var cacheDir: String {
        NSHomeDirectory() + "/Library/Application Support/ADBDAV"
    }
    static var cached: String { cacheDir + "/rclone-\(version)-linux-arm64" }

    /// 없으면 받아서 검증하고 캐시에 둔다. 성공하면 nil, 실패하면 사유를 준다.
    static func ensureDownloaded(progress: (String) -> Void) -> String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: cached) { return nil }

        try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let work = NSTemporaryDirectory() + "adbdav-rclone"
        try? fm.removeItem(atPath: work)
        try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: work) }

        let zip = work + "/" + zipName
        progress(T.s("Downloading rclone \(version) (75 MB, once)...",
                     "rclone \(version) 내려받는 중 (75MB, 최초 1회)..."))
        let dl = Shell.run("/usr/bin/curl", ["-sSL", "--fail", "-o", zip, url], timeout: 600)
        guard dl.ok, fm.fileExists(atPath: zip) else {
            return T.s("Download failed: \(dl.out)", "내려받기 실패: \(dl.out)")
        }

        progress(T.s("Verifying checksum...", "체크섬 확인 중..."))
        let sum = Shell.run("/usr/bin/shasum", ["-a", "256", zip], timeout: 120)
            .out.split(separator: " ").first.map(String.init) ?? ""
        guard sum == sha256 else {
            return T.s("Checksum mismatch. The download may be corrupted or tampered with.\n\nexpected \(sha256)\ngot      \(sum)",
                       "체크섬이 다릅니다. 파일이 손상됐거나 변조됐을 수 있습니다.\n\n기대값 \(sha256)\n실제값 \(sum)")
        }

        progress(T.s("Unpacking...", "압축 푸는 중..."))
        guard Shell.run("/usr/bin/unzip", ["-oq", zip, "-d", work], timeout: 300).ok else {
            return T.s("Failed to unpack the archive.", "압축을 풀지 못했습니다.")
        }
        guard let found = fm.enumerator(atPath: work)?
            .compactMap({ $0 as? String })
            .first(where: { ($0 as NSString).lastPathComponent == "rclone" })
        else {
            return T.s("rclone was not found inside the archive.", "압축 안에 rclone 이 없습니다.")
        }

        try? fm.removeItem(atPath: cached)
        do { try fm.moveItem(atPath: work + "/" + found, toPath: cached) }
        catch { return T.s("Failed to store rclone: \(error.localizedDescription)",
                           "rclone 저장 실패: \(error.localizedDescription)") }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cached)
        return nil
    }
}

// MARK: - adb 래퍼

struct ADB {
    let path: String

    /// 흔한 설치 위치를 순서대로 찾는다. 앱 번들에 동봉된 것을 최우선으로 본다.
    static func locate() -> ADB? {
        var candidates: [String] = []
        if let bundled = Bundle.main.path(forResource: "adb", ofType: nil) {
            candidates.append(bundled)
        }
        candidates += [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return ADB(path: c)
        }
        return nil
    }

    // MARK: 기기 목록

    /// adb 가 아는 모든 기기. 상태는 device, unauthorized, offline 등이 온다.
    func allDevices() -> [(serial: String, state: String, isNetwork: Bool)] {
        let r = Shell.run(path, ["devices"], timeout: 10)
        guard r.ok else { return [] }
        return r.out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 2, !parts[0].isEmpty, !parts[0].hasPrefix("*") else { return nil }
            return (parts[0], parts[1], parts[0].contains(":"))
        }
    }

    /// 바로 쓸 수 있는 기기만. 시리얼에 콜론이 있으면 무선이다.
    func onlineDevices() -> [(serial: String, isNetwork: Bool)] {
        allDevices().filter { $0.state == "device" }.map { ($0.serial, $0.isNetwork) }
    }

    /// mDNS 광고에서 무선 디버깅 주소를 찾는다. 페어링은 이미 되어 있어야 한다.
    func discoverWireless() -> String? {
        let r = Shell.run(path, ["mdns", "services"], timeout: 20)
        for line in r.out.split(separator: "\n") {
            let text = String(line)
            guard text.contains("_adb-tls-connect") else { continue }
            let fields = text.split(separator: "\t").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if let addr = fields.last, addr.contains(":") { return addr }
        }
        return nil
    }

    @discardableResult
    func connectWireless(_ address: String) -> Bool {
        let r = Shell.run(path, ["connect", address], timeout: 20)
        return r.out.lowercased().contains("connected")
    }

    // MARK: 특정 기기 대상 명령

    @discardableResult
    func run(_ serial: String, _ args: [String], timeout: TimeInterval = 20) -> Shell.Result {
        Shell.run(path, ["-s", serial] + args, timeout: timeout)
    }

    @discardableResult
    func shell(_ serial: String, _ command: String, timeout: TimeInterval = 20) -> Shell.Result {
        run(serial, ["shell", command], timeout: timeout)
    }

    func model(_ serial: String) -> String {
        let m = shell(serial, "getprop ro.product.model", timeout: 10).out
        // 연결이 끊기는 순간 "error: closed" 같은 문자열이 그대로 돌아온다.
        if m.isEmpty || m.contains("error") || m.contains("adb:") || m.contains("failed") {
            return "Android"
        }
        return m
    }
}


/// 기기 찾기 결과. 실패하면 사람이 읽을 사유를 담는다.
enum DeviceLookup {
    case found(String)
    case failed(String)
}

// MARK: - USB 하드웨어 진단

/// adb 가 폰을 못 볼 때, 케이블 문제인지 설정 문제인지 갈라주기 위해
/// macOS 의 USB 장치 목록을 직접 들여다본다.
enum USBProbe {
    struct Facts {
        /// adb 전용 인터페이스(클래스 255 / 서브클래스 66)가 열려 있는가
        let adbInterface: Bool
        /// 안드로이드로 보이는 기기가 꽂혀 있는가
        let phoneName: String?
    }

    private static let vendors = ["SAMSUNG", "Galaxy", "Google", "Pixel", "Xiaomi",
                                  "OnePlus", "OPPO", "vivo", "Motorola", "LGE",
                                  "Sony", "HUAWEI", "realme", "Android"]

    static func facts() -> Facts {
        let iface = Shell.run("/usr/sbin/ioreg",
                              ["-r", "-c", "IOUSBHostInterface", "-l"], timeout: 20)
        let hasADB = iface.out.contains("\"bInterfaceSubClass\" = 66")

        let tree = Shell.run("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w", "0"], timeout: 20)
        var name: String?
        for raw in tree.out.split(separator: "\n") {
            let line = String(raw)
            guard line.contains("\"USB Product Name\""),
                  vendors.contains(where: { line.localizedCaseInsensitiveContains($0) }),
                  let eq = line.range(of: "= ")
            else { continue }
            name = line[eq.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            break
        }
        return Facts(adbInterface: hasADB, phoneName: name)
    }
}

// MARK: - 연결 상태

enum LinkState {
    case noADB
    case noDevice(TransportMode)
    case ready(String, TransportMode)
    case mounted(String, TransportMode)
    case working(String)

    var title: String {
        switch self {
        case .noADB:                 return T.s("adb is not installed", "adb가 설치되지 않음")
        case .noDevice(let m):       return T.s("No phone over \(m.label)", "\(m.label)로 연결된 폰 없음")
        case .ready(let n, let m):   return T.s("\(n) ready (\(m.label))", "\(n) 대기 중 (\(m.label))")
        case .mounted(let n, let m): return T.s("\(n) connected (\(m.label))", "\(n) 연결됨 (\(m.label))")
        case .working(let s):        return s
        }
    }

    /// 메뉴바 이미지 이름. 앱 아이콘과 같은 모양의 단색 템플릿이다.
    /// 템플릿이라 밝은 메뉴바와 어두운 메뉴바에서 macOS 가 알아서 색을 맞춘다.
    var imageName: String {
        switch self {
        case .noADB, .noDevice: return "bar_off"
        case .ready, .working:  return "bar_ready"
        case .mounted:          return "bar_mounted"
        }
    }
}

// MARK: - 마운트 관리

final class Linker {
    private let adb: ADB
    init(adb: ADB) { self.adb = adb }

    /// 우리 포트를 쓰는 webdav 마운트의 실제 경로를 찾는다. 없으면 nil.
    var mountPoint: String? {
        let r = Shell.run("/sbin/mount", [], timeout: 10)
        for line in r.out.split(separator: "\n") {
            let text = String(line)
            guard text.contains("webdav"),
                  text.contains(" on \(Config.mountDir) ")
            else { continue }
            return Config.mountDir
        }
        return nil
    }

    var isMounted: Bool { mountPoint != nil }

    /// 터널과 폰 서버가 모두 살아 있는지 한 번에 확인한다.
    /// 케이블을 뽑았다 꽂으면 터널이 사라지는데 마운트 표에는 그대로 남는다.
    /// 그 껍데기를 연결된 상태로 착각하면 영영 다시 붙지 않는다.
    func endpointAlive() -> Bool {
        let r = Shell.run("/usr/bin/curl",
                          ["-s", "-o", "/dev/null", "-w", "%{http_code}",
                           "--max-time", "5", "-X", "PROPFIND",
                           "-H", "Depth: 0", Config.healthURL],
                          timeout: 12)
        return r.out.hasPrefix("2")
    }

    /// 속이 죽은 마운트를 걷어낸다. 이래야 정상 연결 절차가 다시 돈다.
    func clearStaleMount() {
        guard let point = mountPoint else { return }
        _ = Shell.run("/usr/sbin/diskutil", ["unmount", "force", point], timeout: 40)
    }

    /// 원하는 모드에 해당하는 기기를 찾는다. 못 찾으면 왜 못 찾았는지 말해준다.
    func resolveDevice(_ mode: TransportMode) -> DeviceLookup {
        let wantNetwork = (mode == .wifi)
        if let hit = adb.onlineDevices().first(where: { $0.isNetwork == wantNetwork }) {
            return .found(hit.serial)
        }
        // 붙어 있긴 한데 쓸 수 없는 상태인지 먼저 본다
        if let bad = adb.allDevices().first(where: { $0.isNetwork == wantNetwork && $0.state != "device" }) {
            return .failed(reasonForBadState(bad.state))
        }
        if !wantNetwork {
            return .failed(usbReason())
        }
        guard let addr = adb.discoverWireless() else {
            return .failed(T.s("No phone with wireless debugging was found on the network.\n\n"
                + "Check that wireless debugging is on in Developer options. "
                + "It turns itself off when the phone reboots. "
                + "The phone and the Mac must be on the same Wi-Fi, and the link drops when the screen sleeps.",
                "무선 디버깅을 하는 폰이 네트워크에 보이지 않습니다.\n\n"
                + "폰 설정의 개발자 옵션에서 무선 디버깅이 켜져 있는지 확인하세요. "
                + "폰을 재부팅하면 무선 디버깅은 자동으로 꺼집니다. "
                + "폰과 Mac이 같은 Wi-Fi에 있어야 하고, 폰 화면이 꺼지면 연결이 끊어집니다."))
        }
        guard adb.connectWireless(addr) else {
            return .failed(T.s("Found the phone at \(addr) but the connection was refused.\n\n"
                + "Pair the device again from the wireless debugging screen on the phone.",
                "폰을 \(addr) 에서 찾았지만 연결이 거부됐습니다.\n\n"
                + "폰의 무선 디버깅 화면에서 기기 페어링을 다시 해주세요."))
        }
        if let hit = adb.onlineDevices().first(where: { $0.isNetwork }) {
            return .found(hit.serial)
        }
        return .failed(T.s("Connected to the phone but it does not appear in the device list. Toggle wireless debugging off and on.", "폰에 연결했지만 목록에 나타나지 않습니다. 폰의 무선 디버깅을 껐다 켜보세요."))
    }

    private func reasonForBadState(_ state: String) -> String {
        switch state {
        case "unauthorized":
            return T.s("The phone is asking whether to trust this computer.\n\n"
                + "Tap Allow. Check \"Always allow\" so it stops asking.",
                "폰 화면에 이 컴퓨터를 신뢰할지 묻는 창이 떠 있습니다.\n\n"
                + "허용을 눌러주세요. 항상 허용에 체크하면 다음부터는 묻지 않습니다.")
        case "offline":
            return T.s("The phone is not responding.\n\nUnplug the cable and plug it back in.", "폰이 응답하지 않습니다.\n\n케이블을 뽑았다 다시 꽂아보세요.")
        default:
            return T.s("The phone reports state '\(state)'.\n\nReplug the cable or restart the phone.", "폰 상태가 '\(state)' 입니다.\n\n케이블을 다시 꽂거나 폰을 재부팅해보세요.")
        }
    }

    /// USB 로 못 찾았을 때, 하드웨어를 직접 확인해 무엇이 문제인지 짚어준다.
    private func usbReason() -> String {
        let f = USBProbe.facts()
        if f.adbInterface {
            return T.s("The phone exposes its debug interface but adb does not see it.\n\n"
                + "Unplug and replug the cable. If that does not help, run "
                + "adb kill-server in Terminal and try again.",
                "폰이 디버깅 통로를 열었는데 adb가 인식하지 못합니다.\n\n"
                + "케이블을 뽑았다 다시 꽂아보세요. 그래도 안 되면 터미널에서 "
                + "adb kill-server 를 실행한 뒤 다시 시도하세요.")
        }
        if let name = f.phoneName {
            return T.s("\(name) is plugged in over USB but USB debugging is off.\n\n"
                + "Turn on USB debugging in Developer options. "
                + "If wireless debugging is on, turn it off first. "
                + "Samsung phones cannot use both at once.",
                "\(name) 이(가) USB로 연결돼 있지만 USB 디버깅이 꺼져 있습니다.\n\n"
                + "폰 설정의 개발자 옵션에서 USB 디버깅을 켜주세요. "
                + "무선 디버깅이 켜져 있으면 먼저 끄셔야 합니다. "
                + "삼성 기기는 두 가지를 동시에 쓰지 못합니다.")
        }
        return T.s("No phone is connected over USB.\n\n"
            + "Check that the cable is seated, and that it is not a charge-only cable.",
            "USB로 연결된 폰이 없습니다.\n\n"
            + "케이블이 제대로 꽂혔는지, 충전 전용 케이블은 아닌지 확인하세요.")
    }

    /// 폰에 rclone이 없으면 넣어준다. 없으면 먼저 내려받아 검증한다.
    private func ensureBinary(_ serial: String, progress: (String) -> Void) -> String? {
        if adb.shell(serial, "[ -x \(Config.remoteBinary) ] && echo yes", timeout: 12).out == "yes" {
            return nil
        }
        if let e = RClone.ensureDownloaded(progress: progress) { return e }
        let local = RClone.cached
        progress(T.s("Copying rclone to the phone...", "폰으로 rclone 복사 중..."))
        let push = adb.run(serial, ["push", local, Config.remoteBinary], timeout: 300)
        guard push.ok else { return T.s("Failed to copy rclone: \(push.out)", "rclone 전송 실패: \(push.out)") }
        guard adb.shell(serial, "chmod 755 \(Config.remoteBinary)", timeout: 15).ok else {
            return T.s("Failed to make rclone executable", "rclone 권한 설정 실패")
        }
        return nil
    }

    private func startServer(_ serial: String) -> String? {
        // 서버가 떠 있다고 그냥 쓰면 안 된다. 설정(포트, 볼륨 이름)이 바뀌었는데
        // 옛 설정으로 도는 서버를 재사용하면 엉뚱한 주소를 물고 마운트가 실패한다.
        // 대괄호는 grep 이 자기 자신을 잡지 않게 하는 기법이다.
        let running = adb.shell(serial, "ps -A -o ARGS | grep '[r]clone'", timeout: 12).out
        if !running.isEmpty {
            let matchesConfig = running.contains("127.0.0.1:\(Config.port)")
                && running.contains(Config.sharedPath)
                && !running.contains("--baseurl")
            if matchesConfig { return nil }
            _ = adb.shell(serial, "pkill -x rclone", timeout: 12)
            Thread.sleep(forTimeInterval: 1.5)
        }
        let cmd = "nohup \(Config.remoteBinary) serve webdav \(Config.sharedPath) "
            + "--addr 127.0.0.1:\(Config.port) "
            + "> \(Config.remoteLog) 2>&1 &"
        _ = adb.shell(serial, cmd, timeout: 25)
        Thread.sleep(forTimeInterval: 3.5)

        let up = adb.shell(serial, "pgrep -x rclone >/dev/null && echo yes", timeout: 12).out == "yes"
        return up ? nil : T.s("The server did not start on the phone.", "폰에서 서버가 시작되지 않았습니다.")
    }

    private func openTunnel(_ serial: String) -> String? {
        let list = adb.run(serial, ["forward", "--list"], timeout: 12).out
        if list.contains("tcp:\(Config.port)") { return nil }
        let r = adb.run(serial, ["forward", "tcp:\(Config.port)", "tcp:\(Config.port)"], timeout: 20)
        return r.ok ? nil : T.s("Failed to open the tunnel: \(r.out)", "터널 생성 실패: \(r.out)")
    }

    private func mount() -> String? {
        let dir = Config.mountDir
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir,
                                                     withIntermediateDirectories: true)
        }
        // -S 는 인증창 같은 UI 를 막고, 서버가 응답을 멈추면 바로 언마운트한다.
        // 죽은 마운트가 남는 걸 줄여준다.
        var lastOutput = ""
        for host in Config.hostCandidates {
            let r = Shell.run("/sbin/mount_webdav",
                              ["-S", "-v", Config.baseURL, Config.mountURL(host: host), dir],
                              timeout: 40)
            Thread.sleep(forTimeInterval: 1.5)
            if isMounted { return nil }
            lastOutput = r.out
        }
        return T.s("Mount failed: ", "마운트 실패: ") + (lastOutput.isEmpty ? T.s("unknown error", "알 수 없는 오류") : lastOutput)
    }

    /// 전체 연결 과정. 실패하면 사람이 읽을 수 있는 사유를 돌려준다.
    func connect(_ mode: TransportMode, progress: @escaping (String) -> Void) -> String? {
        progress(T.s("Looking for a \(mode.label) device...", "\(mode.label) 기기 찾는 중..."))
        let serial: String
        switch resolveDevice(mode) {
        case .found(let s): serial = s
        case .failed(let why): return why
        }
        progress(T.s("Checking rclone...", "rclone 확인 중..."))
        if let e = ensureBinary(serial, progress: progress) { return e }
        progress(T.s("Starting the server...", "서버 시작 중..."))
        if let e = startServer(serial) { return e }
        progress(T.s("Opening the tunnel...", "터널 연결 중..."))
        if let e = openTunnel(serial) { return e }
        progress(T.s("Mounting in Finder...", "Finder에 마운트 중..."))
        if let e = mount() { return e }
        return nil
    }

    func disconnect(_ mode: TransportMode) {
        if let point = mountPoint {
            _ = Shell.run("/usr/sbin/diskutil", ["unmount", "force", point], timeout: 40)
        }
        guard let serial = adb.onlineDevices()
            .first(where: { $0.isNetwork == (mode == .wifi) })?.serial else { return }
        _ = adb.run(serial, ["forward", "--remove", "tcp:\(Config.port)"], timeout: 12)
        _ = adb.shell(serial, "pkill -x rclone", timeout: 12)
    }

    func revealInFinder() {
        guard let point = mountPoint else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: point))
    }
}

// MARK: - 메뉴바 앱

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var adb: ADB?
    private var linker: Linker?
    private var state: LinkState = .noADB
    private var busy = false
    private var lastAutoFailure: Date?

    private let autoKey = "autoConnect"
    private let modeKey = "transportMode"
    private let langKey = "language"

    private var autoConnect: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    private var mode: TransportMode {
        get {
            let raw = UserDefaults.standard.string(forKey: modeKey) ?? TransportMode.usb.rawValue
            return TransportMode(rawValue: raw) ?? .usb
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        adb = ADB.locate()
        if let adb { linker = Linker(adb: adb) }
        if UserDefaults.standard.object(forKey: autoKey) == nil { autoConnect = true }
        if let raw = UserDefaults.standard.string(forKey: langKey),
           let saved = Lang(rawValue: raw) { T.lang = saved }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        linker?.disconnect(mode)
    }

    // MARK: 상태 갱신

    private func refresh() {
        guard !busy else { return }
        let currentMode = mode
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let newState = self.probe(currentMode)
            DispatchQueue.main.async {
                let wasReady: Bool
                if case .ready = self.state { wasReady = true } else { wasReady = false }
                let previousTitle = self.state.title
                self.state = newState
                self.render()

                // 기기를 새로 인식했고 자동 연결이 켜져 있으면 바로 붙인다
                var isReady = false
                if case .ready = newState { isReady = true }
                if newState.title != previousTitle {
                    Log.write("state: \(newState.title)")
                }

                // 자동 연결. 실패 직후 곧바로 다시 달려들지 않도록 잠시 쉰다.
                let cooling = self.lastAutoFailure.map { Date().timeIntervalSince($0) < 30 } ?? false
                if self.autoConnect, isReady, !wasReady, !cooling {
                    self.connect(manual: false)
                }
            }
        }
    }

    /// 폴링 중에는 무선 탐색까지 하지 않는다. 이미 붙어 있는 것만 본다.
    private func probe(_ m: TransportMode) -> LinkState {
        guard let adb, let linker else { return .noADB }
        let wantNetwork = (m == .wifi)
        guard let hit = adb.onlineDevices().first(where: { $0.isNetwork == wantNetwork }) else {
            return .noDevice(m)
        }
        let name = adb.model(hit.serial)
        guard linker.isMounted else { return .ready(name, m) }
        if linker.endpointAlive() { return .mounted(name, m) }

        Log.write("clearing an unresponsive mount")
        linker.clearStaleMount()
        return .ready(name, m)
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let img = NSImage(named: state.imageName)
            ?? NSImage(systemSymbolName: "iphone", accessibilityDescription: state.title)
        img?.isTemplate = true
        img?.size = NSSize(width: 18, height: 18)
        button.image = img
        button.image?.accessibilityDescription = state.title
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: state.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        switch state {
        case .mounted:
            menu.addItem(item(T.s("Open in Finder", "Finder에서 열기"), #selector(openFinder), key: "o"))
            menu.addItem(item(T.s("Disconnect", "연결 해제"), #selector(disconnect), key: "d"))
        case .ready:
            menu.addItem(item(T.s("Connect", "연결하기"), #selector(connectFromMenu), key: "c"))
        case .noADB:
            menu.addItem(hint(T.s("Run brew install android-platform-tools", "터미널에서 brew install android-platform-tools")))
        case .noDevice(let m):
            menu.addItem(item(T.s("Try to connect", "연결 시도"), #selector(connectFromMenu), key: "c"))
            menu.addItem(hint(m == .usb ? T.s("Plug in the USB cable", "USB 케이블을 연결하세요") : T.s("Turn on wireless debugging on the phone", "폰의 무선 디버깅을 켜세요")))
        case .working:
            break
        }

        menu.addItem(.separator())

        // 연결 모드 하위 메뉴
        let modeItem = NSMenuItem(title: T.s("Connection", "연결 모드"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in [TransportMode.usb, .wifi] {
            let mi = NSMenuItem(title: m.label,
                                action: #selector(changeMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.rawValue
            mi.state = (mode == m) ? .on : .off
            sub.addItem(mi)
        }
        modeItem.submenu = sub
        menu.addItem(modeItem)

        // 표시 언어 하위 메뉴
        let langItem = NSMenuItem(title: T.s("Language", "언어"), action: nil, keyEquivalent: "")
        let langSub = NSMenu()
        for l in Lang.allCases {
            let li = NSMenuItem(title: l.label, action: #selector(changeLang(_:)), keyEquivalent: "")
            li.target = self
            li.representedObject = l.rawValue
            li.state = (T.lang == l) ? .on : .off
            langSub.addItem(li)
        }
        langItem.submenu = langSub
        menu.addItem(langItem)

        let auto = item(T.s("Connect automatically", "인식하면 자동 연결"), #selector(toggleAuto), key: "")
        auto.state = autoConnect ? .on : .off
        menu.addItem(auto)

        let login = item(T.s("Launch at login", "로그인 시 실행"), #selector(toggleLaunchAtLogin), key: "")
        switch SMAppService.mainApp.status {
        case .enabled:          login.state = .on
        case .requiresApproval: login.state = .mixed
        default:                login.state = .off
        }
        menu.addItem(login)
        if SMAppService.mainApp.status == .requiresApproval {
            menu.addItem(hint(T.s("Approve it in System Settings, Login Items",
                                  "시스템 설정의 로그인 항목에서 허용해 주세요")))
        }

        menu.addItem(.separator())
        menu.addItem(item(T.s("Quit", "종료"), #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ sel: Selector, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func hint(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: 동작

    @objc private func changeMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let newMode = TransportMode(rawValue: raw),
              newMode != mode, !busy else { return }

        let oldMode = mode
        let wasMounted = linker?.isMounted ?? false
        mode = newMode
        busy = true
        state = .working(T.s("Switching to \(newMode.label)...", "\(newMode.label)로 전환 중..."))
        render()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let linker = self.linker else { return }
            if wasMounted { linker.disconnect(oldMode) }
            let error = linker.connect(newMode) { msg in
                DispatchQueue.main.async {
                    self.state = .working(msg)
                    self.render()
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                if let error { self.alert(T.s("\(newMode.label) connection failed", "\(newMode.label) 연결 실패"), error) }
                self.refresh()
            }
        }
    }

    @objc private func connectFromMenu() { connect(manual: true) }

    private func connect(manual: Bool) {
        guard let linker, !busy else { return }
        let m = mode
        busy = true
        state = .working(T.s("Connecting...", "연결 중..."))
        render()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let error = linker.connect(m) { msg in
                DispatchQueue.main.async {
                    self.state = .working(msg)
                    self.render()
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                Log.write("connect(\(manual ? "manual" : "auto")): \(error ?? "ok")")
                if let error {
                    self.lastAutoFailure = Date()
                    // 자동 시도 실패는 조용히 넘긴다. 3초마다 경고창이 뜨면 못 쓴다.
                    if manual { self.alert(T.s("Could not connect", "연결하지 못했습니다"), error) }
                } else {
                    self.lastAutoFailure = nil
                }
                self.refresh()
            }
        }
    }

    @objc private func disconnect() {
        guard let linker, !busy else { return }
        let m = mode
        busy = true
        state = .working(T.s("Disconnecting...", "해제 중..."))
        render()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            linker.disconnect(m)
            DispatchQueue.main.async {
                self?.busy = false
                self?.refresh()
            }
        }
    }

    @objc private func openFinder() { linker?.revealInFinder() }

    @objc private func changeLang(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let chosen = Lang(rawValue: raw) else { return }
        T.lang = chosen
        UserDefaults.standard.set(raw, forKey: langKey)
        render()
    }

    /// 로그인 항목 등록. macOS 13 부터 제공되는 SMAppService 를 쓴다.
    /// 예전처럼 LaunchAgents 에 파일을 심지 않아 흔적이 남지 않는다.
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert(T.s("Could not change the login item", "로그인 항목을 바꾸지 못했습니다"),
                  T.s("\(error.localizedDescription)\n\nIf the app is not in the Applications folder, move it there and try again.",
                      "\(error.localizedDescription)\n\n앱이 응용 프로그램 폴더에 있지 않으면 옮긴 뒤 다시 시도해 주세요."))
        }
        render()
    }

    @objc private func toggleAuto() {
        autoConnect.toggle()
        render()
    }

    @objc private func quit() {
        linker?.disconnect(mode)
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: T.s("OK", "확인"))
        a.runModal()
    }
}

// MARK: - 진입점

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
