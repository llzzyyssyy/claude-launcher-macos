import AppKit
import Darwin
import Foundation
import SwiftUI

// MARK: - Command execution

struct CommandResult {
    let status: Int32
    let output: String
}

private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) -> CommandResult {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        // A private /dev/null handle. The shared FileHandle.nullDevice can be
        // closed by Process and then break later launches.
        if let nullInput = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = nullInput
        }

        let output = PipeBuffer()
        let errors = PipeBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            output.append(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errors.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.closeFile()
            errPipe.fileHandleForReading.closeFile()
            _ = group.wait(timeout: .now() + 1)
            return CommandResult(status: -1, output: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        let text = String(data: output.snapshot() + errors.snapshot(), encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: text)
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Local HTTP over a Unix socket

enum UnixSocketHTTP {
    struct Result {
        let status: Int
        let body: String
    }

    static func send(
        socketPath: String,
        method: String,
        path: String,
        body: Data?,
        bearer: String?,
        timeout: TimeInterval
    ) -> Result? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = socketPath.withCString { source -> Bool in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                guard let base = buffer.baseAddress, socketPath.utf8.count < buffer.count else { return false }
                _ = strlcpy(base.assumingMemoryBound(to: CChar.self), source, buffer.count)
                return true
            }
        }
        guard copied else { return nil }

        var time = timeval()
        time.tv_sec = time_t(max(1, Int(timeout)))
        time.tv_usec = 0
        let timeSize = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, timeSize)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, timeSize)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.connect(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connected == 0 else { return nil }

        var header = "\(method) \(path) HTTP/1.0\r\nHost: localhost\r\nAccept: application/json\r\nConnection: close\r\n"
        if let bearer, isSafeToken(bearer) {
            header += "Authorization: Bearer \(bearer)\r\n"
        }
        var payload = Data(header.utf8)
        if let body {
            payload.append(Data("Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8))
            payload.append(body)
        } else {
            payload.append(Data("\r\n".utf8))
        }
        guard writeAll(fd: fd, data: payload) else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while response.count < 262_144 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
            } else {
                break
            }
        }
        guard let text = String(data: response, encoding: .utf8),
              let message = HTTPMessage.split(text) else { return nil }
        return Result(status: message.status, body: message.body)
    }

    private static func isSafeToken(_ token: String) -> Bool {
        !token.isEmpty && !token.contains("\n") && !token.contains("\r") && !token.contains(" ")
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
    }
}

private func pathExists(_ path: String) -> Bool {
    path.withCString { pointer in
        var info = Darwin.stat()
        return lstat(pointer, &info) == 0
    }
}

// MARK: - Log

enum LauncherLog {
    private static let lock = NSLock()
    static let displayPath = "~/Library/Logs/ClaudeLauncher/launcher.log"

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeLauncher/launcher.log")
    }

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var line = LogRedactor.redact(message).replacingOccurrences(of: "\n", with: " ")
        if line.count > 1000 {
            line = String(line.prefix(1000)) + "…"
        }
        let text = "\(stamp) \(line)\n"
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            // A log failure must not stop the launch flow.
        }
    }
}

// MARK: - IP detection

struct IPCheckResult {
    let trace: TraceResult
    let countryName: String

    var locationDisplay: String {
        countryName
    }
}

enum IPDetector {
    private static func synchronousRequest(_ request: URLRequest, timeout: TimeInterval) -> (Data?, Error?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        var receivedData: Data?
        var receivedError: Error?
        let task = session.dataTask(with: request) { data, _, error in
            receivedData = data
            receivedError = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            return (nil, NSError(domain: "ClaudePrep", code: 1, userInfo: [NSLocalizedDescriptionKey: "检测请求超时"]))
        }
        session.invalidateAndCancel()
        return (receivedData, receivedError)
    }

    static func detect() -> Result<IPCheckResult, Error> {
        guard let traceURL = URL(string: "https://claude.ai/cdn-cgi/trace") else {
            return .failure(NSError(domain: "ClaudePrep", code: 2, userInfo: [NSLocalizedDescriptionKey: "检测地址无效"]))
        }
        var traceRequest = URLRequest(url: traceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        traceRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        traceRequest.setValue(LauncherVersion.userAgent, forHTTPHeaderField: "User-Agent")
        let (traceData, traceError) = synchronousRequest(traceRequest, timeout: 12)
        if let traceError { return .failure(traceError) }
        guard let traceData,
              let traceText = String(data: traceData, encoding: .utf8),
              let trace = TraceParser.parse(traceText) else {
            return .failure(NSError(domain: "ClaudePrep", code: 3, userInfo: [NSLocalizedDescriptionKey: "未能从 Claude 读取出口 IP 和地区"]))
        }

        return .success(IPCheckResult(trace: trace, countryName: countryName(for: trace.countryCode)))
    }

    static func countryName(for code: String) -> String {
        Locale(identifier: "zh_CN").localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }
}

// MARK: - Clash Verge service mode

enum ClashController {
    struct SilenceResult {
        var notes: [String] = []
        var ports: Set<Int> = []
        var sawClash = false
    }

    private static let vergePorts: Set<Int> = [7890, 7891, 7892, 7893, 7897, 7898, 7899]

    static func silence() -> SilenceResult {
        var result = SilenceResult()
        let discovered = configFiles()
        let secrets = discovered.secrets
        let sockets = candidateSockets(extra: discovered.sockets)
        if sockets.isEmpty {
            LauncherLog.write("clash controller socket not found")
            return result
        }
        for socket in sockets {
            silence(socket: socket, secrets: secrets, into: &result)
        }
        result.notes = uniqueStrings(result.notes)
        result.ports.formUnion(result.sawClash ? vergePorts : [])
        return result
    }

    static func capturePresent() -> Bool {
        let parts = [
            Shell.run("/sbin/ifconfig", ["-a"], timeout: 5).output,
            Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"], timeout: 5).output,
            Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet6"], timeout: 5).output,
            Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 5).output
        ]
        return NetworkAudit.hasClashCapture(in: parts.joined(separator: "\n"))
    }

    private static func silence(socket: String, secrets: [String], into result: inout SilenceResult) {
        guard var probe = UnixSocketHTTP.send(socketPath: socket, method: "GET", path: "/version", body: nil, bearer: nil, timeout: 3) else {
            LauncherLog.write("clash socket unreachable \(socket)")
            return
        }
        var bearer: String?
        if probe.status == 401 {
            for secret in secrets {
                guard let authed = UnixSocketHTTP.send(socketPath: socket, method: "GET", path: "/version", body: nil, bearer: secret, timeout: 3),
                      (200..<300).contains(authed.status) else { continue }
                bearer = secret
                probe = authed
                break
            }
        }
        if !(200..<300).contains(probe.status),
           let root = UnixSocketHTTP.send(socketPath: socket, method: "GET", path: "/", body: nil, bearer: bearer, timeout: 3),
           (200..<300).contains(root.status) {
            probe = root
        }
        guard (200..<300).contains(probe.status) else {
            LauncherLog.write("clash version status=\(probe.status) socket=\(socket)")
            return
        }
        result.sawClash = true
        LauncherLog.write("clash controller reachable \(socket)")

        var tunEnabled: Bool?
        if let configs = UnixSocketHTTP.send(socketPath: socket, method: "GET", path: "/configs", body: nil, bearer: bearer, timeout: 3),
           (200..<300).contains(configs.status),
           let runtime = ClashRuntimeParser.parse(configs.body) {
            result.ports.formUnion(runtime.ports)
            tunEnabled = runtime.tunEnabled
        }
        if tunEnabled == false {
            result.notes.append("Clash 内核在运行，TUN 已关闭")
            return
        }

        let body = Data(ClashRuntimeParser.disableTunBody.utf8)
        let patched = UnixSocketHTTP.send(socketPath: socket, method: "PATCH", path: "/configs", body: body, bearer: bearer, timeout: 5)
        if let patched, (200..<300).contains(patched.status) {
            result.notes.append("已关闭 Clash TUN")
            _ = UnixSocketHTTP.send(socketPath: socket, method: "DELETE", path: "/connections", body: nil, bearer: bearer, timeout: 3)
            LauncherLog.write("clash tun disabled \(socket)")
        } else {
            LauncherLog.write("clash tun patch failed status=\(patched?.status ?? -1) socket=\(socket)")
        }
    }

    private static func candidateSockets(extra: [String]) -> [String] {
        var paths = extra
        let ps = Shell.run("/bin/ps", ["-axww", "-o", "command="], timeout: 5)
        paths.append(contentsOf: ClashProcess.controllerSockets(fromPS: ps.output))
        paths.append("/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock")
        paths.append("/tmp/verge/verge-mihomo.sock")
        if let tmp = getenv("TMPDIR") {
            paths.append(URL(fileURLWithPath: String(cString: tmp)).appendingPathComponent("verge-mihomo.sock").path)
        }
        return uniqueStrings(paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter(pathExists)
    }

    private static func configFiles() -> (sockets: [String], secrets: [String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundles = [
            "io.github.clash-verge-rev.clash-verge-rev",
            "io.github.clash-verge-rev.clash-verge-rev.dev"
        ]
        var sockets: [String] = []
        var secrets: [String] = []
        for bundle in bundles {
            for name in ["clash-verge.yaml", "config.yaml"] {
                let path = "\(home)/Library/Application Support/\(bundle)/\(name)"
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                if let socket = ClashYAML.externalControllerUnix(in: text) { sockets.append(socket) }
                if let secret = ClashYAML.secret(in: text) { secrets.append(secret) }
            }
        }
        LauncherLog.write("clash config sockets=\(sockets.count)")
        return (sockets, uniqueStrings(secrets))
    }
}

enum SystemProxyCleaner {
    static func disableLoopbackClashProxies(ports: Set<Int>) -> Result<String, Error> {
        guard !ports.isEmpty else { return .success("") }
        let list = Shell.run("/usr/sbin/networksetup", ["-listallnetworkservices"], timeout: 8)
        guard list.status == 0 else {
            LauncherLog.write("networksetup list failed status=\(list.status)")
            return .success("")
        }
        var disabled: [String] = []
        var leftover: (service: String, server: String, port: Int)?
        for service in NetworkServiceList.parse(list.output) {
            let kinds: [(get: String, set: String, label: String)] = [
                ("-getwebproxy", "-setwebproxystate", "网页"),
                ("-getsecurewebproxy", "-setsecurewebproxystate", "安全网页"),
                ("-getsocksfirewallproxy", "-setsocksfirewallproxystate", "SOCKS")
            ]
            for kind in kinds {
                let info = Shell.run("/usr/sbin/networksetup", [kind.get, service], timeout: 8)
                guard let setting = SystemProxyParser.parse(info.output),
                      setting.enabled,
                      SystemProxyParser.isLoopback(setting.server),
                      ports.contains(setting.port) else { continue }
                let off = Shell.run("/usr/sbin/networksetup", [kind.set, service, "off"], timeout: 8)
                let again = Shell.run("/usr/sbin/networksetup", [kind.get, service], timeout: 8)
                let stillOn = SystemProxyParser.parse(again.output)?.enabled == true
                if off.status == 0 && !stillOn {
                    disabled.append("\(service) \(kind.label):\(setting.port)")
                    LauncherLog.write("system proxy off service=\(service) kind=\(kind.label) port=\(setting.port)")
                } else if stillOn {
                    leftover = (service, setting.server, setting.port)
                    LauncherLog.write("system proxy remains service=\(service) port=\(setting.port) status=\(off.status)")
                }
            }
        }
        if let leftover {
            return .failure(launcherError(ClashMessages.proxyRemains(server: leftover.server, port: leftover.port, service: leftover.service), code: 33))
        }
        if disabled.isEmpty { return .success("") }
        return .success("已关闭系统代理（\(disabled.joined(separator: "、"))）")
    }
}

// MARK: - Tailscale command line

enum TailscaleCLI {
    static func resolve() -> String? {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let which = Shell.run("/usr/bin/which", ["tailscale"], timeout: 3)
        let found = which.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if which.status == 0, found.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }
}

// MARK: - Workflow model

enum StepState {
    case idle
    case running
    case success
    case failure
    case warning

    var logName: String {
        switch self {
        case .idle: return "idle"
        case .running: return "running"
        case .success: return "success"
        case .failure: return "failure"
        case .warning: return "warning"
        }
    }
}

struct WorkflowStep: Identifiable {
    let id: Int
    let title: String
    var detail: String
    var state: StepState
}

final class WorkflowModel: ObservableObject {
    @Published var steps: [WorkflowStep] = WorkflowModel.makeSteps()
    @Published var isRunning = false
    @Published var isShuttingDown = false
    @Published var summary = "点击上方按钮，按顺序准备并启动"
    @Published var ipDisplay = "尚未检测"

    private let tailscaleName = "Tailscale"

    func runAll() {
        guard !isRunning else { return }
        reset()
        isRunning = true
        summary = "正在执行准备流程…"
        LauncherLog.write("workflow start version=\(LauncherVersion.marketing)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performFullWorkflow()
        }
    }

    func launchManually() {
        guard !isRunning else { return }
        reset()
        steps[0].detail = "手动启动：跳过此步骤"
        steps[1].detail = "手动启动：跳过此步骤"
        steps[4] = WorkflowStep(id: 4, title: "手动启动 Claude", detail: "等待出口检测结果", state: .idle)
        isRunning = true
        setStep(2, state: .running, detail: "正在检测 Claude 出口…")
        setStep(3, state: .idle, detail: "等待地区判断")
        setStep(4, state: .idle, detail: "等待地区判断")
        updateSummary("手动启动前，正在重新检测出口 IP…")
        LauncherLog.write("manual launch start version=\(LauncherVersion.marketing)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performIPCheckAndLaunch()
        }
    }

    func shutDown() {
        guard !isRunning else { return }
        steps = Self.makeShutdownSteps()
        ipDisplay = "本次关闭不检测出口"
        isRunning = true
        isShuttingDown = true
        summary = "正在关闭 Claude 和 Tailscale…"
        LauncherLog.write("shutdown start version=\(LauncherVersion.marketing)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performShutdown()
        }
    }

    private static func makeSteps() -> [WorkflowStep] {
        [
            WorkflowStep(id: 0, title: "关闭其他 VPN", detail: "Clash、Shadowrocket 等", state: .idle),
            WorkflowStep(id: 1, title: "启动并连接 Tailscale", detail: "以 Tailscale 后端状态为准", state: .idle),
            WorkflowStep(id: 2, title: "检测出口 IP", detail: "由 App 直接检测", state: .idle),
            WorkflowStep(id: 3, title: "附加检查", detail: "时区、DNS、IPv6，仅提示", state: .idle),
            WorkflowStep(id: 4, title: "自动启动 Claude", detail: "仅支持地区自动启动", state: .idle)
        ]
    }

    private static func makeShutdownSteps() -> [WorkflowStep] {
        [
            WorkflowStep(id: 0, title: "退出 Claude", detail: "仅退出 /Applications/Claude.app", state: .idle),
            WorkflowStep(id: 1, title: "断开 Tailscale", detail: "tailscale down，保留出口节点设置", state: .idle),
            WorkflowStep(id: 2, title: "退出 Tailscale", detail: "后端停止后再退出 App", state: .idle)
        ]
    }

    private func reset() {
        steps = Self.makeSteps()
        ipDisplay = "尚未检测"
    }

    private func performFullWorkflow() {
        setStep(0, state: .running, detail: "正在关闭其他 VPN…")
        switch closeOtherVPNs() {
        case .success(let detail):
            setStep(0, state: .success, detail: detail)
        case .failure(let error):
            setStep(0, state: .failure, detail: error.localizedDescription)
            setStep(1, state: .idle, detail: "上一步失败，未连接")
            setStep(2, state: .idle, detail: "尚未检测")
            setStep(3, state: .idle, detail: "尚未检查")
            setStep(4, state: .idle, detail: "尚未启动")
            finish("关闭其他 VPN 失败，已停止流程")
            return
        }

        setStep(1, state: .running, detail: "正在确认 Tailscale 后端…")
        switch connectTailscale() {
        case .success(let message):
            setStep(1, state: .success, detail: message)
        case .failure(let error):
            setStep(1, state: .failure, detail: error.localizedDescription)
            setStep(2, state: .idle, detail: "Tailscale 连通后再检测")
            setStep(3, state: .idle, detail: "尚未检查")
            setStep(4, state: .idle, detail: "尚未启动")
            finish("Tailscale 没有连上，请看这一步的说明后重试")
            return
        }

        setStep(2, state: .running, detail: "正在检测 Claude 出口…")
        performIPCheckAndLaunch()
    }

    private func performShutdown() {
        LauncherLog.write("shutdown leaves Clash untouched")
        var problems: [String] = []

        setStep(0, state: .running, detail: "正在退出 Claude…")
        switch quitApplication(
            at: "/Applications/Claude.app",
            bundleIDs: ["com.anthropic.claudefordesktop"],
            displayName: "Claude"
        ) {
        case .success(let detail):
            setStep(0, state: .success, detail: detail)
        case .failure(let error):
            setStep(0, state: .failure, detail: error.localizedDescription)
            problems.append(error.localizedDescription)
        }

        setStep(1, state: .running, detail: "正在执行 tailscale down…")
        let backend = stopTailscaleBackend()
        switch backend {
        case .success(let detail):
            setStep(1, state: .success, detail: detail)
        case .failure(let error):
            setStep(1, state: .failure, detail: error.localizedDescription)
            problems.append(error.localizedDescription)
        }

        setStep(2, state: .running, detail: "正在退出 Tailscale…")
        switch quitTailscaleApp(backendWasDown: {
            if case .success = backend { return true }
            return false
        }()) {
        case .success(let detail):
            setStep(2, state: .success, detail: detail)
        case .failure(let error):
            setStep(2, state: .failure, detail: error.localizedDescription)
            problems.append(error.localizedDescription)
        }

        if problems.isEmpty {
            finish("Claude 和 Tailscale 已关闭。Clash 保持原样，需要时请自行打开")
        } else {
            finish("关闭未完成：\(problems.joined(separator: "；"))")
        }
    }

    private func closeOtherVPNs() -> Result<String, Error> {
        let knownBundleIDs: Set<String> = [
            "io.github.clash-verge-rev.clash-verge-rev",
            "io.github.clash-verge-rev.clash-verge-rev.dev",
            "com.follow.clash",
            "com.liguangming.Shadowrocket",
            "com.wwss.WWSS",
            "com.github.yichengchen.clashX",
            "com.nssurge.surge-mac",
            "net.mullvad.vpn",
            "com.expressvpn.ExpressVPN",
            "com.nordvpn.macos"
        ]
        let keywords = ["vpn", "clash", "shadowrocket", "surge", "v2ray", "sing-box", "wireguard", "outline", "flclash", "西部世界"]
        var targeted: [NSRunningApplication] = []

        DispatchQueue.main.sync {
            targeted = NSWorkspace.shared.runningApplications.filter { app in
                let bundleID = (app.bundleIdentifier ?? "").lowercased()
                let name = (app.localizedName ?? "").lowercased()
                if bundleID == "io.tailscale.ipn.macsys" || bundleID == "com.tailscale.ipn.macos" || name == "tailscale" { return false }
                if bundleID == Bundle.main.bundleIdentifier?.lowercased() { return false }
                if knownBundleIDs.contains(where: { $0.lowercased() == bundleID }) { return true }
                return keywords.contains(where: { name.contains($0) || bundleID.contains($0) })
            }
            for app in targeted { _ = app.terminate() }
        }

        Thread.sleep(forTimeInterval: 1.5)
        DispatchQueue.main.sync {
            for app in targeted where !app.isTerminated { _ = app.forceTerminate() }
        }
        Thread.sleep(forTimeInterval: 0.4)
        let stillRunning = targeted.filter { !$0.isTerminated }.compactMap(\.localizedName)
        if !stillRunning.isEmpty {
            LauncherLog.write("vpn apps still running \(stillRunning.joined(separator: ","))")
            return .failure(launcherError("未能退出：\(stillRunning.joined(separator: "、"))", code: 30))
        }

        let sawClashApp = targeted.contains { app in
            let bundleID = (app.bundleIdentifier ?? "").lowercased()
            let name = (app.localizedName ?? "").lowercased()
            return bundleID.contains("clash") || name.contains("clash") || name.contains("verge")
        }

        let listResult = Shell.run("/usr/sbin/scutil", ["--nc", "list"])
        guard listResult.status == 0 else {
            return .failure(launcherError("无法读取 VPN 服务列表：\(listResult.output)", code: 31))
        }
        let serviceNames = VPNServiceParser.serviceNames(from: listResult.output, excluding: tailscaleName)
        for service in serviceNames {
            let stopped = Shell.run("/usr/sbin/scutil", ["--nc", "stop", service], timeout: 8)
            guard stopped.status == 0 else {
                return .failure(launcherError("停止 VPN 服务 \(service) 失败：\(stopped.output)", code: 32))
            }
        }

        let captureBefore = ClashController.capturePresent()
        LauncherLog.write("clash capture before=\(captureBefore) app=\(sawClashApp)")
        let silence = ClashController.silence()
        let involved = silence.sawClash || captureBefore || sawClashApp
        if involved {
            let deadline = Date().addingTimeInterval(6)
            var present = ClashController.capturePresent()
            while present && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.4)
                present = ClashController.capturePresent()
            }
            LauncherLog.write("clash capture after=\(present)")
            if present {
                return .failure(launcherError(ClashMessages.tunRemains, code: 34))
            }
            var ports = silence.ports
            ports.formUnion([7890, 7891, 7892, 7893, 7897, 7898, 7899])
            switch SystemProxyCleaner.disableLoopbackClashProxies(ports: ports) {
            case .failure(let error):
                return .failure(error)
            case .success(let note):
                if !note.isEmpty {
                    var notes = silence.notes
                    notes.append(note)
                    return successDetail(apps: targeted, services: serviceNames, notes: notes)
                }
            }
        }

        return successDetail(apps: targeted, services: serviceNames, notes: silence.notes)
    }

    private func successDetail(apps: [NSRunningApplication], services: [String], notes: [String]) -> Result<String, Error> {
        var pieces: [String] = []
        let appNames = uniqueStrings(apps.compactMap(\.localizedName))
        if !appNames.isEmpty { pieces.append(appNames.joined(separator: "、")) }
        if !services.isEmpty { pieces.append(services.joined(separator: "、")) }
        pieces.append(contentsOf: notes)
        if pieces.isEmpty { return .success("未发现正在运行的其他 VPN") }
        return .success("已处理：\(pieces.joined(separator: "；"))")
    }

    private func connectTailscale() -> Result<String, Error> {
        // Readiness comes from `tailscale status --json`, not `scutil --nc status`.
        // On Demand can mark the system VPN connected while BackendState is Stopped.
        let appPath = "/Applications/Tailscale.app"
        guard FileManager.default.fileExists(atPath: appPath) else {
            return .failure(launcherError(TailscaleMessages.appMissing, code: 10))
        }
        guard let cli = TailscaleCLI.resolve() else {
            return .failure(launcherError(TailscaleMessages.cliMissing, code: 13))
        }
        LauncherLog.write("tailscale cli=\(cli)")

        if !tailscaleAppIsRunning() {
            LauncherLog.write("opening Tailscale.app")
            let opened = Shell.run("/usr/bin/open", [appPath], timeout: 8)
            guard opened.status == 0 else {
                return .failure(launcherError("打开 Tailscale 失败：\(opened.output.trimmingCharacters(in: .whitespacesAndNewlines))", code: 11))
            }
        } else {
            LauncherLog.write("Tailscale.app already running")
        }

        let prefsResult = Shell.run(cli, ["debug", "prefs"], timeout: 8)
        let prefs = TailscalePrefsParser.parse(prefsResult.output)
        LauncherLog.write("prefs wantRunning=\(String(describing: prefs?.wantRunning)) loggedOut=\(String(describing: prefs?.loggedOut)) hasExitNode=\(prefs?.hasExitNode == true)")

        let started = Date()
        let deadline = started.addingTimeInterval(30)
        var upAttempts = 0
        var upError: String?
        var upFinishedAt: Date?
        var last: TailscaleStatus?
        var sawStatus = false

        while Date() < deadline {
            let statusResult = Shell.run(cli, ["status", "--json"], timeout: 8)
            if let status = TailscaleStatusParser.parse(statusResult.output) {
                sawStatus = true
                last = status
                LauncherLog.write("backend=\(status.backendState) selfOnline=\(status.selfOnline) exitSet=\(status.exitNode != nil) exitOnline=\(String(describing: status.exitNode?.online))")
                if status.isReady {
                    return .success(TailscaleMessages.success(status))
                }
                if status.blocker == .notLoggedIn || (prefs?.loggedOut == true && status.backendState.lowercased() != "running") {
                    return .failure(launcherError(TailscaleMessages.failure(blocker: .notLoggedIn, hasSavedExitNode: prefs?.hasExitNode == true), code: 14))
                }
                if status.blocker == .needsMachineAuth {
                    return .failure(launcherError(TailscaleMessages.failure(blocker: .needsMachineAuth, hasSavedExitNode: false), code: 15))
                }
                if status.blocker == .noExitNode {
                    let anchor = upFinishedAt ?? started
                    if Date().timeIntervalSince(anchor) > 5 {
                        return .failure(launcherError(TailscaleMessages.failure(blocker: .noExitNode, hasSavedExitNode: prefs?.hasExitNode == true), code: 16))
                    }
                }
                let loggedOut = prefs?.loggedOut == true || status.loggedOut == true
                if status.shouldBringUp && !loggedOut && upAttempts < 2 {
                    upAttempts += 1
                    LauncherLog.write("bringing tailscale up attempt=\(upAttempts)")
                    upError = bringTailscaleUp(cli)
                    upFinishedAt = Date()
                }
            } else {
                let snippet = statusResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                LauncherLog.write("tailscale status unavailable code=\(statusResult.status) output=\(String(snippet.prefix(200)))")
            }
            Thread.sleep(forTimeInterval: 0.8)
        }

        if let last, let blocker = last.blocker {
            var message = TailscaleMessages.failure(blocker: blocker, hasSavedExitNode: prefs?.hasExitNode == true)
            if let upError, blocker == .backendStopped || blocker == .starting {
                message += " \(upError)"
            }
            return .failure(launcherError(message, code: 12))
        }
        if !sawStatus {
            var message = TailscaleMessages.serviceUnreachable
            if let upError { message += " \(upError)" }
            return .failure(launcherError(message, code: 17))
        }
        return .failure(launcherError(TailscaleMessages.failure(blocker: .backendStopped, hasSavedExitNode: prefs?.hasExitNode == true), code: 12))
    }

    private func bringTailscaleUp(_ cli: String) -> String? {
        let first = Shell.run(cli, ["up"], timeout: 18)
        LauncherLog.write("tailscale up status=\(first.status) output=\(String(first.output.prefix(400)))")
        if first.status == 0 { return nil }
        if let arguments = TailscaleUpSuggestion.arguments(from: first.output) {
            LauncherLog.write("tailscale up retry argc=\(arguments.count)")
            let second = Shell.run(cli, ["up"] + arguments, timeout: 18)
            LauncherLog.write("tailscale up retry status=\(second.status) output=\(String(second.output.prefix(400)))")
            if second.status == 0 { return nil }
            return TailscaleMessages.upFailed(second.output)
        }
        return TailscaleMessages.upFailed(first.output)
    }

    private func tailscaleAppIsRunning() -> Bool {
        var running = false
        DispatchQueue.main.sync {
            running = NSWorkspace.shared.runningApplications.contains { app in
                let identifier = app.bundleIdentifier ?? ""
                return identifier == "io.tailscale.ipn.macsys" || identifier == "com.tailscale.ipn.macos"
            }
        }
        return running
    }

    private func performIPCheckAndLaunch() {
        switch IPDetector.detect() {
        case .failure(let error):
            setStep(2, state: .failure, detail: error.localizedDescription)
            setStep(3, state: .idle, detail: "尚未检查")
            setStep(4, state: .idle, detail: "未启动")
            finish("IP 检测失败，Claude App 没有启动")
        case .success(let result):
            let ipVersion = result.trace.ip.contains(":") ? "IPv6" : "IPv4"
            let display = "\(result.trace.ip)  ·  \(result.locationDisplay)  ·  \(ipVersion)"
            DispatchQueue.main.async { [weak self] in self?.ipDisplay = display }
            LauncherLog.write("egress ip=\(result.trace.ip) loc=\(result.trace.countryCode) allowed=\(result.trace.isSupportedRegion)")
            if result.trace.isSupportedRegion {
                setStep(2, state: .success, detail: "支持地区：\(result.locationDisplay)（\(result.trace.countryCode)）")
                let warnings = collectExtraWarnings(trace: result.trace, countryName: result.locationDisplay)
                if warnings.isEmpty {
                    setStep(3, state: .success, detail: "时区、DNS 和 IPv6 未发现明显问题")
                } else {
                    setStep(3, state: .warning, detail: warnings.joined(separator: "；") + "。仅提示，不阻止启动")
                }
                setStep(4, state: .running, detail: "正在打开 Claude App…")
                switch launchClaudeApp() {
                case .success(let appPath):
                    setStep(4, state: .success, detail: "已启动：\(appPath)")
                    if warnings.isEmpty {
                        finish("出口位于支持地区，Claude App 已启动")
                    } else {
                        finish("出口位于支持地区，Claude App 已启动。另有 \(warnings.count) 条环境提示")
                    }
                case .failure(let error):
                    setStep(4, state: .failure, detail: error.localizedDescription)
                    finish("地区检测通过，但 Claude App 启动失败")
                }
            } else {
                setStep(2, state: .failure, detail: "当前为 \(result.locationDisplay)（\(result.trace.countryCode)），未列入支持地区")
                setStep(3, state: .idle, detail: "地区未通过，跳过")
                setStep(4, state: .idle, detail: "地区未通过：未启动")
                finish("当前出口未列入 Claude 支持地区，未启动")
            }
        }
    }

    private func collectExtraWarnings(trace: TraceResult, countryName: String) -> [String] {
        let zone = TimeZone.current
        let dns = Shell.run("/usr/sbin/scutil", ["--dns"], timeout: 6)
        let ipv6 = probeIPv6Country()
        let warnings = ExtraCheckReport.warnings(
            trace: trace,
            countryName: countryName,
            now: Date(),
            timeZoneID: zone.identifier,
            gmtOffsetMinutes: zone.secondsFromGMT() / 60,
            dnsOutput: dns.output,
            ipv6Country: ipv6
        )
        LauncherLog.write("extra warnings=\(warnings.count) tz=\(zone.identifier) offsetMin=\(zone.secondsFromGMT() / 60) ipv6=\(ipv6 ?? "none")")
        return warnings
    }

    private func probeIPv6Country() -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else { return nil }
        let result = Shell.run("/usr/bin/curl", [
            "-6", "-sS", "--max-time", "8", "--noproxy", "*",
            "-H", "Cache-Control: no-cache",
            "-A", LauncherVersion.userAgent,
            "https://claude.ai/cdn-cgi/trace"
        ], timeout: 12)
        guard result.status == 0, let trace = TraceParser.parse(result.output) else {
            LauncherLog.write("ipv6 probe none status=\(result.status)")
            return nil
        }
        return trace.countryCode
    }

    private func launchClaudeApp() -> Result<String, Error> {
        let appPath = "/Applications/Claude.app"
        guard FileManager.default.fileExists(atPath: appPath) else {
            return .failure(NSError(domain: "ClaudePrep", code: 20, userInfo: [NSLocalizedDescriptionKey: "没有找到 /Applications/Claude.app，请先确认 Claude App 已安装"]))
        }
        let opened = Shell.run("/usr/bin/open", [appPath], timeout: 8)
        guard opened.status == 0 else {
            let message = opened.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(NSError(domain: "ClaudePrep", code: 21, userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Claude App 没有成功打开" : message]))
        }
        return .success(appPath)
    }

    private func setStep(_ index: Int, state: StepState, detail: String) {
        LauncherLog.write("step=\(index) state=\(state.logName) \(detail)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.steps.indices.contains(index) else { return }
            self.steps[index].state = state
            self.steps[index].detail = detail
        }
    }

    private func updateSummary(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.summary = value }
    }

    private func finish(_ value: String) {
        LauncherLog.write("finish \(value)")
        DispatchQueue.main.async { [weak self] in
            self?.summary = value
            self?.isRunning = false
            self?.isShuttingDown = false
        }
    }

    private func quitApplication(at bundlePath: String, bundleIDs: Set<String>, displayName: String) -> Result<String, Error> {
        var matches: [NSRunningApplication] = []
        DispatchQueue.main.sync {
            matches = NSWorkspace.shared.runningApplications.filter { app in
                if let identifier = app.bundleIdentifier, bundleIDs.contains(identifier) { return true }
                let path = app.bundleURL?.path ?? ""
                return path == bundlePath || path.hasPrefix(bundlePath + "/")
            }
            for app in matches { _ = app.terminate() }
        }
        if matches.isEmpty {
            LauncherLog.write("quit \(displayName) not running")
            return .success("\(displayName) 未在运行")
        }
        Thread.sleep(forTimeInterval: 1.2)
        DispatchQueue.main.sync {
            for app in matches where !app.isTerminated { _ = app.forceTerminate() }
        }
        Thread.sleep(forTimeInterval: 0.4)
        let still = matches.filter { !$0.isTerminated }.compactMap(\.localizedName)
        if !still.isEmpty {
            LauncherLog.write("quit \(displayName) still running")
            return .failure(launcherError("未能退出 \(displayName)", code: 45))
        }
        LauncherLog.write("quit \(displayName) ok")
        return .success("已退出 \(displayName)")
    }

    private func stopTailscaleBackend() -> Result<String, Error> {
        guard let cli = TailscaleCLI.resolve() else {
            return .failure(launcherError(TailscaleMessages.cliMissing, code: 40))
        }
        LauncherLog.write("tailscale down cli=\(cli)")
        let down = Shell.run(cli, TailscaleShutdown.downArguments, timeout: 20)
        LauncherLog.write("tailscale down status=\(down.status) output=\(String(down.output.prefix(400)))")

        let deadline = Date().addingTimeInterval(15)
        var last: TailscaleStatus?
        while Date() < deadline {
            let statusResult = Shell.run(cli, ["status", "--json"], timeout: 8)
            if let status = TailscaleStatusParser.parse(statusResult.output) {
                last = status
                LauncherLog.write("shutdown backend=\(status.backendState) wantRunning=\(String(describing: status.wantRunning))")
                if TailscaleShutdown.isDown(status) {
                    let prefsResult = Shell.run(cli, ["debug", "prefs"], timeout: 8)
                    let prefs = TailscalePrefsParser.parse(prefsResult.output)
                    LauncherLog.write("shutdown prefs wantRunning=\(String(describing: prefs?.wantRunning)) hasExitNode=\(prefs?.hasExitNode == true)")
                    if prefs?.wantRunning == true {
                        return .failure(launcherError("tailscale down 之后后端仍要求保持运行", code: 41))
                    }
                    let kept = prefs?.hasExitNode == true ? "原来的出口节点设置已保留" : "后端已停止"
                    return .success("后端已停止（\(status.backendState)）。\(kept)")
                }
            } else {
                let snippet = statusResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                LauncherLog.write("shutdown status unavailable code=\(statusResult.status) output=\(String(snippet.prefix(200)))")
            }
            Thread.sleep(forTimeInterval: 0.6)
        }
        if let last {
            return .failure(launcherError("Tailscale 后端仍是 \(last.backendState)，出口还可能在转发流量", code: 42))
        }
        if down.status != 0 {
            return .failure(launcherError(TailscaleMessages.downFailed(down.output), code: 43))
        }
        return .failure(launcherError("无法确认 Tailscale 后端已停止", code: 44))
    }

    private func quitTailscaleApp(backendWasDown: Bool) -> Result<String, Error> {
        let quit = quitApplication(
            at: "/Applications/Tailscale.app",
            bundleIDs: ["io.tailscale.ipn.macsys", "com.tailscale.ipn.macos"],
            displayName: "Tailscale"
        )
        if case .failure(let error) = quit {
            return .failure(error)
        }
        guard let cli = TailscaleCLI.resolve() else {
            if backendWasDown {
                return .success("\(quitMessage(quit))。关闭前后端已停止")
            }
            return .failure(launcherError("已退出 Tailscale，但找不到命令行，无法确认后端已停止", code: 46))
        }
        var last: TailscaleStatus?
        for _ in 0..<4 {
            let statusResult = Shell.run(cli, ["status", "--json"], timeout: 5)
            if let status = TailscaleStatusParser.parse(statusResult.output) {
                last = status
                LauncherLog.write("shutdown after quit backend=\(status.backendState)")
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        let quitDetail = quitMessage(quit)
        if let last {
            if TailscaleShutdown.isDown(last) {
                return .success("\(quitDetail)。系统 VPN 开关若仍显示已连接，那是按需连接留下的状态，流量已不再走出口节点")
            }
            return .failure(launcherError("退出 Tailscale 后后端仍是 \(last.backendState)，出口还可能在转发流量", code: 47))
        }
        if backendWasDown {
            return .success("\(quitDetail)。退出后已读不到 Tailscale 状态，关闭前后端已停止。系统 VPN 开关若仍显示已连接，流量已不再走出口节点")
        }
        return .failure(launcherError("退出 Tailscale 后无法确认后端已停止", code: 48))
    }

    private func quitMessage(_ result: Result<String, Error>) -> String {
        if case .success(let detail) = result { return detail }
        return "已退出 Tailscale"
    }
}

private func launcherError(_ message: String, code: Int) -> NSError {
    NSError(domain: "ClaudeLauncher", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for value in values where !value.isEmpty && seen.insert(value).inserted {
        result.append(value)
    }
    return result
}

// MARK: - SwiftUI view

private struct RectButtonStyle: ButtonStyle {
    enum Role {
        case launch
        case shutdown
    }

    var role: Role
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(shape.fill(fill(pressed: configuration.isPressed)))
            .overlay(shape.strokeBorder(border, lineWidth: role == .shutdown ? 1 : 0))
            .opacity(isEnabled ? 1 : 0.42)
    }

    private var foreground: Color {
        switch role {
        case .launch:
            return .white
        case .shutdown:
            return Color(red: 0.62, green: 0.22, blue: 0.20)
        }
    }

    private func fill(pressed: Bool) -> Color {
        switch role {
        case .launch:
            return pressed
                ? Color(red: 0.08, green: 0.40, blue: 0.43)
                : Color(red: 0.14, green: 0.46, blue: 0.49)
        case .shutdown:
            return Color(red: 0.62, green: 0.22, blue: 0.20).opacity(pressed ? 0.16 : 0.08)
        }
    }

    private var border: Color {
        Color(red: 0.62, green: 0.22, blue: 0.20).opacity(0.38)
    }
}

private struct StepRow: View {
    let step: WorkflowStep

    private var color: Color {
        switch step.state {
        case .idle: return Color.secondary.opacity(0.55)
        case .running: return .orange
        case .success: return .green
        case .failure: return .red
        case .warning: return Color(red: 0.85, green: 0.55, blue: 0.05)
        }
    }

    private var symbol: String {
        switch step.state {
        case .idle: return "\(step.id + 1)"
        case .running: return "…"
        case .success: return "✓"
        case .failure: return "!"
        case .warning: return "△"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.15))
                Circle().stroke(color, lineWidth: 1.5)
                Text(symbol)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(step.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(detailColor)
                    .lineLimit(4)
            }
            Spacer(minLength: 0)
            if step.state == .running {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 7)
    }

    private var detailColor: Color {
        switch step.state {
        case .failure: return .red
        case .warning: return Color(red: 0.72, green: 0.42, blue: 0.05)
        default: return .secondary
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: WorkflowModel

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 25, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude 启动器")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("VPN → 支持地区 → 自动启动")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 13)
            .background(
                LinearGradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.22), Color(red: 0.05, green: 0.32, blue: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )

            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    Button(action: model.runAll) {
                        HStack(spacing: 6) {
                            if model.isRunning && !model.isShuttingDown {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Image(systemName: model.isRunning && !model.isShuttingDown ? "hourglass" : "play.fill")
                            Text(model.isRunning && !model.isShuttingDown ? "正在执行…" : "一键启动")
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(RectButtonStyle(role: .launch))
                    .disabled(model.isRunning)

                    Button(action: model.shutDown) {
                        HStack(spacing: 6) {
                            if model.isShuttingDown {
                                ProgressView().controlSize(.small)
                            }
                            Image(systemName: model.isShuttingDown ? "hourglass" : "stop.fill")
                            Text(model.isShuttingDown ? "正在关闭…" : "一键关闭")
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(RectButtonStyle(role: .shutdown))
                    .disabled(model.isRunning)
                    .help("关闭 Claude 和 Tailscale，不重新打开 Clash")
                }
                .padding(.top, 16)
                .padding(.bottom, 18)

                ForEach(model.steps) { step in
                    StepRow(step: step)
                    if step.id != model.steps.last?.id { Divider().opacity(0.55) }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("当前 Claude 出口")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(model.ipDisplay)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 11)

                Text(model.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 11)

                Button("手动启动 Claude", action: model.launchManually)
                    .buttonStyle(.bordered)
                    .disabled(model.isRunning)
                    .padding(.top, 12)

                HStack(spacing: 5) {
                    Image(systemName: "lock.shield")
                    Text("手动启动也会先检测 IP；失败则停止")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.top, 10)

                Text(LauncherLog.displayPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)

                Text("版本 \(appVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 15)
            .background(.ultraThickMaterial)
        }
        .frame(width: 372)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 10)
    }
}

// MARK: - App shell

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let model = WorkflowModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Claude 启动器")
        let aboutItem = appMenu.addItem(withTitle: "关于 Claude 启动器", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "退出 Claude 启动器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString(
            string: "联系邮箱：roylau3366@gmail.com",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        let emailRange = (credits.string as NSString).range(of: "roylau3366@gmail.com")
        credits.addAttributes([
            .link: URL(string: "mailto:roylau3366@gmail.com")!,
            .foregroundColor: NSColor.linkColor
        ], range: emailRange)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func buildWindow() {
        let hosting = NSHostingController(rootView: ContentView(model: model))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Claude 启动器"
        window.titleVisibility = .hidden
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize
        if fitted.width > 200 && fitted.height > 200 {
            window.setContentSize(fitted)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

// MARK: - Command-line modes

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTests())
}

if CommandLine.arguments.contains("--check-current-ip") {
    switch IPDetector.detect() {
    case .success(let result):
        print("ip=\(result.trace.ip)")
        print("country_code=\(result.trace.countryCode)")
        print("location=\(result.locationDisplay)")
        print("allowed_to_launch=\(result.trace.isSupportedRegion ? "yes" : "no")")
        exit(0)
    case .failure(let error):
        fputs("IP CHECK FAILED: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
