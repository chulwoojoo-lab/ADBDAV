// 안드로이드 폰을 USB 또는 Wi-Fi(adb)로 WebDAV 마운트해 Finder에 연결하는 메뉴바 앱

import AppKit

// MARK: - 설정

enum Config {
    static let port = 8090
    static let baseURL = "PhoneLink"          // Finder 볼륨 이름이 된다
    static let remoteBinary = "/data/local/tmp/rclone"
    static let remoteLog = "/data/local/tmp/rclone.log"
    static let sharedPath = "/sdcard"
    static var serveURL: String { "http://127.0.0.1:\(port)/\(baseURL)" }
    static var fallbackURL: String { "http://127.0.0.1:\(port)/" }
}

/// 폰에 닿는 경로. 같은 adb를 쓰지만 USB 쪽이 30배 이상 빠르다.
enum TransportMode: String {
    case usb
    case wifi

    var label: String { self == .usb ? "USB" : "Wi-Fi" }
}


// MARK: - 진단 로그

enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/PhoneLink.log"
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
            return Result(code: 127, out: "실행 파일 없음: \(path)")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do { try task.run() } catch {
            return Result(code: 126, out: "실행 실패: \(error.localizedDescription)")
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
            return Result(code: 124, out: "시간 초과")
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

    /// 붙어 있는 기기들. 시리얼에 콜론이 있으면 무선이다.
    func onlineDevices() -> [(serial: String, isNetwork: Bool)] {
        let r = Shell.run(path, ["devices"], timeout: 10)
        guard r.ok else { return [] }
        return r.out
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasSuffix("\tdevice") }
            .compactMap { line in
                let serial = line.replacingOccurrences(of: "\tdevice", with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard !serial.isEmpty else { return nil }
                return (serial, serial.contains(":"))
            }
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
        return m.isEmpty ? "Android" : m
    }

    /// 화면이 잠겨 있으면 안드로이드가 저장소를 노출하지 않는다.
    func isLocked(_ serial: String) -> Bool {
        let r = shell(serial, "dumpsys window 2>/dev/null | grep -o 'mDreamingLockscreen=[a-z]*'", timeout: 12)
        return r.out.contains("true")
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
        case .noADB:                 return "adb가 설치되지 않음"
        case .noDevice(let m):       return "\(m.label)로 연결된 폰 없음"
        case .ready(let n, let m):   return "\(n) 대기 중 (\(m.label))"
        case .mounted(let n, let m): return "\(n) 연결됨 (\(m.label))"
        case .working(let s):        return s
        }
    }

    var symbol: String {
        switch self {
        case .noADB, .noDevice: return "iphone.slash"
        case .ready:            return "iphone"
        case .mounted:          return "iphone.badge.checkmark"
        case .working:          return "iphone.gen3"
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
            guard text.contains("127.0.0.1:\(Config.port)"),
                  text.contains("webdav"),
                  let onRange = text.range(of: " on "),
                  let parenRange = text.range(of: " (", range: onRange.upperBound..<text.endIndex)
            else { continue }
            return String(text[onRange.upperBound..<parenRange.lowerBound])
        }
        return nil
    }

    var isMounted: Bool { mountPoint != nil }

    /// 원하는 모드에 해당하는 기기를 찾는다. 무선인데 안 붙어 있으면 붙여본다.
    func resolveDevice(_ mode: TransportMode) -> String? {
        let wantNetwork = (mode == .wifi)
        if let hit = adb.onlineDevices().first(where: { $0.isNetwork == wantNetwork }) {
            return hit.serial
        }
        guard wantNetwork, let addr = adb.discoverWireless() else { return nil }
        guard adb.connectWireless(addr) else { return nil }
        return adb.onlineDevices().first(where: { $0.isNetwork })?.serial
    }

    /// 폰에 rclone이 없으면 번들에서 밀어 넣는다.
    private func ensureBinary(_ serial: String) -> String? {
        if adb.shell(serial, "[ -x \(Config.remoteBinary) ] && echo yes", timeout: 12).out == "yes" {
            return nil
        }
        guard let local = Bundle.main.path(forResource: "rclone-arm64", ofType: nil) else {
            return "앱에 rclone 바이너리가 없습니다."
        }
        let push = adb.run(serial, ["push", local, Config.remoteBinary], timeout: 180)
        guard push.ok else { return "rclone 전송 실패: \(push.out)" }
        guard adb.shell(serial, "chmod 755 \(Config.remoteBinary)", timeout: 15).ok else {
            return "rclone 권한 설정 실패"
        }
        return nil
    }

    private func startServer(_ serial: String) -> String? {
        // pgrep -f 는 확인 명령 자신의 명령줄까지 훑어 오탐이 난다. -x 로 이름만 본다.
        if adb.shell(serial, "pgrep -x rclone >/dev/null && echo yes", timeout: 12).out == "yes" {
            return nil
        }
        let cmd = "nohup \(Config.remoteBinary) serve webdav \(Config.sharedPath) "
            + "--addr 127.0.0.1:\(Config.port) --baseurl /\(Config.baseURL) "
            + "> \(Config.remoteLog) 2>&1 &"
        _ = adb.shell(serial, cmd, timeout: 25)
        Thread.sleep(forTimeInterval: 3.5)

        let up = adb.shell(serial, "pgrep -x rclone >/dev/null && echo yes", timeout: 12).out == "yes"
        return up ? nil : "폰에서 서버가 시작되지 않았습니다."
    }

    private func openTunnel(_ serial: String) -> String? {
        let list = adb.run(serial, ["forward", "--list"], timeout: 12).out
        if list.contains("tcp:\(Config.port)") { return nil }
        let r = adb.run(serial, ["forward", "tcp:\(Config.port)", "tcp:\(Config.port)"], timeout: 20)
        return r.ok ? nil : "터널 생성 실패: \(r.out)"
    }

    private func mount() -> String? {
        // 볼륨 이름을 예쁘게 하려고 baseurl 주소를 먼저 시도하고,
        // 안 되면 루트 주소로 되돌린다. 어느 쪽이든 붙기만 하면 된다.
        var lastOutput = ""
        for url in [Config.serveURL, Config.fallbackURL] {
            let r = Shell.run("/usr/bin/osascript", ["-e", "mount volume \"\(url)\""], timeout: 60)
            Thread.sleep(forTimeInterval: 1.5)
            if isMounted { return nil }
            lastOutput = r.out
        }
        return "Finder 마운트 실패: \(lastOutput)"
    }

    /// 전체 연결 과정. 실패하면 사람이 읽을 수 있는 사유를 돌려준다.
    func connect(_ mode: TransportMode, progress: @escaping (String) -> Void) -> String? {
        progress("\(mode.label) 기기 찾는 중...")
        guard let serial = resolveDevice(mode) else {
            return mode == .usb
                ? "USB로 연결된 폰이 없습니다. 케이블을 확인하세요."
                : "무선으로 찾을 수 없습니다. 폰의 무선 디버깅이 켜져 있는지 확인하세요."
        }
        if adb.isLocked(serial) {
            return "폰 화면이 잠겨 있습니다. 잠금을 풀고 다시 시도하세요."
        }
        progress("rclone 확인 중...")
        if let e = ensureBinary(serial) { return e }
        progress("서버 시작 중...")
        if let e = startServer(serial) { return e }
        progress("터널 연결 중...")
        if let e = openTunnel(serial) { return e }
        progress("Finder에 마운트 중...")
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
                    Log.write("상태: \(newState.title)")
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
        return linker.isMounted ? .mounted(name, m) : .ready(name, m)
    }

    private func render() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.title)
        button.image?.isTemplate = true
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
            menu.addItem(item("Finder에서 열기", #selector(openFinder), key: "o"))
            menu.addItem(item("연결 해제", #selector(disconnect), key: "d"))
        case .ready:
            menu.addItem(item("연결하기", #selector(connectFromMenu), key: "c"))
        case .noADB:
            menu.addItem(hint("터미널에서 brew install android-platform-tools"))
        case .noDevice(let m):
            menu.addItem(item("연결 시도", #selector(connectFromMenu), key: "c"))
            menu.addItem(hint(m == .usb ? "USB 케이블을 연결하세요" : "폰의 무선 디버깅을 켜세요"))
        case .working:
            break
        }

        menu.addItem(.separator())

        // 연결 모드 하위 메뉴
        let modeItem = NSMenuItem(title: "연결 모드", action: nil, keyEquivalent: "")
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

        let auto = item("인식하면 자동 연결", #selector(toggleAuto), key: "")
        auto.state = autoConnect ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())
        menu.addItem(item("종료", #selector(quit), key: "q"))
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
        state = .working("\(newMode.label)로 전환 중...")
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
                if let error { self.alert("\(newMode.label) 연결 실패", error) }
                self.refresh()
            }
        }
    }

    @objc private func connectFromMenu() { connect(manual: true) }

    private func connect(manual: Bool) {
        guard let linker, !busy else { return }
        let m = mode
        busy = true
        state = .working("연결 중...")
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
                Log.write("연결 시도(\(manual ? "수동" : "자동")) 결과: \(error ?? "성공")")
                if let error {
                    self.lastAutoFailure = Date()
                    // 자동 시도 실패는 조용히 넘긴다. 3초마다 경고창이 뜨면 못 쓴다.
                    if manual { self.alert("연결하지 못했습니다", error) }
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
        state = .working("해제 중...")
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
        a.addButton(withTitle: "확인")
        a.runModal()
    }
}

// MARK: - 진입점

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
