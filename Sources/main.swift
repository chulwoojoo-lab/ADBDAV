// 안드로이드 폰을 USB(adb)로 WebDAV 마운트해 Finder에 연결하는 메뉴바 앱

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
        var data = Data()
        let handle = pipe.fileHandleForReading

        DispatchQueue.global().async {
            data = handle.readDataToEndOfFile()
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
        let text = String(data: data, encoding: .utf8) ?? ""
        return Result(code: task.terminationStatus, out: text.trimmingCharacters(in: .whitespacesAndNewlines))
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

    @discardableResult
    func run(_ args: [String], timeout: TimeInterval = 20) -> Shell.Result {
        Shell.run(path, args, timeout: timeout)
    }

    @discardableResult
    func shell(_ command: String, timeout: TimeInterval = 20) -> Shell.Result {
        run(["shell", command], timeout: timeout)
    }

    /// 연결된 기기의 모델명을 돌려준다. 없으면 nil.
    func connectedModel() -> String? {
        let r = run(["devices"], timeout: 8)
        guard r.ok else { return nil }
        let online = r.out
            .split(separator: "\n")
            .dropFirst()
            .filter { $0.hasSuffix("\tdevice") }
        guard !online.isEmpty else { return nil }

        let model = shell("getprop ro.product.model", timeout: 8).out
        return model.isEmpty ? "Android" : model
    }

    /// 화면이 잠겨 있으면 안드로이드가 저장소를 노출하지 않는다.
    func isLocked() -> Bool {
        let r = shell("dumpsys window 2>/dev/null | grep -o 'mDreamingLockscreen=[a-z]*'", timeout: 10)
        return r.out.contains("true")
    }
}

// MARK: - 연결 상태

enum LinkState: Equatable {
    case noADB
    case noDevice
    case ready(String)      // 기기 있음, 미연결
    case mounted(String)    // 연결됨
    case working(String)    // 작업 중

    var title: String {
        switch self {
        case .noADB:            return "adb가 설치되지 않음"
        case .noDevice:         return "폰이 연결되지 않음"
        case .ready(let m):     return "\(m) 대기 중"
        case .mounted(let m):   return "\(m) 연결됨"
        case .working(let s):   return s
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
        let r = Shell.run("/sbin/mount", [], timeout: 8)
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

    /// 폰에 rclone이 없으면 번들에서 밀어 넣는다.
    private func ensureBinary() -> String? {
        if adb.shell("[ -x \(Config.remoteBinary) ] && echo yes", timeout: 10).out == "yes" {
            return nil
        }
        guard let local = Bundle.main.path(forResource: "rclone-arm64", ofType: nil) else {
            return "앱에 rclone 바이너리가 없습니다."
        }
        let push = adb.run(["push", local, Config.remoteBinary], timeout: 120)
        guard push.ok else { return "rclone 전송 실패: \(push.out)" }
        let chmod = adb.shell("chmod 755 \(Config.remoteBinary)", timeout: 15)
        guard chmod.ok else { return "rclone 권한 설정 실패" }
        return nil
    }

    private func startServer() -> String? {
        if adb.shell("pgrep -f rclone >/dev/null && echo yes", timeout: 10).out == "yes" {
            return nil
        }
        let cmd = "nohup \(Config.remoteBinary) serve webdav \(Config.sharedPath) "
            + "--addr 127.0.0.1:\(Config.port) --baseurl /\(Config.baseURL) "
            + "> \(Config.remoteLog) 2>&1 &"
        _ = adb.shell(cmd, timeout: 20)
        Thread.sleep(forTimeInterval: 3.5)

        let up = adb.shell("pgrep -f rclone >/dev/null && echo yes", timeout: 10).out == "yes"
        return up ? nil : "폰에서 서버가 시작되지 않았습니다."
    }

    private func openTunnel() -> String? {
        let list = adb.run(["forward", "--list"], timeout: 10).out
        if list.contains("tcp:\(Config.port)") { return nil }
        let r = adb.run(["forward", "tcp:\(Config.port)", "tcp:\(Config.port)"], timeout: 15)
        return r.ok ? nil : "USB 터널 생성 실패: \(r.out)"
    }

    private func mount() -> String? {
        // 볼륨 이름을 예쁘게 하려고 baseurl 주소를 먼저 시도하고,
        // 안 되면 루트 주소로 되돌린다. 어느 쪽이든 붙기만 하면 된다.
        var lastOutput = ""
        for url in [Config.serveURL, Config.fallbackURL] {
            let r = Shell.run("/usr/bin/osascript", ["-e", "mount volume \"\(url)\""], timeout: 40)
            Thread.sleep(forTimeInterval: 1.5)
            if isMounted { return nil }
            lastOutput = r.out
        }
        return "Finder 마운트 실패: \(lastOutput)"
    }

    /// 전체 연결 과정. 실패하면 사람이 읽을 수 있는 사유를 돌려준다.
    func connect(progress: @escaping (String) -> Void) -> String? {
        if adb.isLocked() {
            return "폰 화면이 잠겨 있습니다. 잠금을 풀고 다시 시도하세요."
        }
        progress("rclone 확인 중...")
        if let e = ensureBinary() { return e }
        progress("서버 시작 중...")
        if let e = startServer() { return e }
        progress("USB 터널 연결 중...")
        if let e = openTunnel() { return e }
        progress("Finder에 마운트 중...")
        if let e = mount() { return e }
        return nil
    }

    func disconnect() {
        if let point = mountPoint {
            _ = Shell.run("/usr/sbin/diskutil", ["unmount", "force", point], timeout: 30)
        }
        _ = adb.run(["forward", "--remove", "tcp:\(Config.port)"], timeout: 10)
        _ = adb.shell("pkill -f rclone", timeout: 10)
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
    private var state: LinkState = .noDevice
    private var busy = false

    private let autoKey = "autoConnect"
    private var autoConnect: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
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
        linker?.disconnect()
    }

    // MARK: 상태 갱신

    private func refresh() {
        guard !busy else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let newState = self.probe()
            DispatchQueue.main.async {
                let wasNotReady: Bool
                if case .ready = self.state { wasNotReady = false } else { wasNotReady = true }
                self.state = newState
                self.render()

                // 기기를 새로 꽂았고 자동 연결이 켜져 있으면 바로 붙인다
                if self.autoConnect, case .ready = newState, wasNotReady {
                    self.connect()
                }
            }
        }
    }

    private func probe() -> LinkState {
        guard let adb, let linker else { return .noADB }
        guard let model = adb.connectedModel() else { return .noDevice }
        return linker.isMounted ? .mounted(model) : .ready(model)
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
            menu.addItem(item("연결하기", #selector(connect), key: "c"))
        case .noADB:
            let hint = NSMenuItem(title: "터미널에서 brew install android-platform-tools", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        case .noDevice:
            let hint = NSMenuItem(title: "USB로 폰을 연결하세요", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        case .working:
            break
        }

        menu.addItem(.separator())
        let auto = item("꽂으면 자동 연결", #selector(toggleAuto), key: "")
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

    // MARK: 동작

    @objc private func connect() {
        guard let linker, !busy else { return }
        busy = true
        state = .working("연결 중...")
        render()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let error = linker.connect { msg in
                DispatchQueue.main.async {
                    self.state = .working(msg)
                    self.render()
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                if let error {
                    self.alert("연결하지 못했습니다", error)
                }
                self.refresh()
            }
        }
    }

    @objc private func disconnect() {
        guard let linker, !busy else { return }
        busy = true
        state = .working("해제 중...")
        render()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            linker.disconnect()
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
        linker?.disconnect()
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
