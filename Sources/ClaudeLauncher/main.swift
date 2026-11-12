import AppKit
import Foundation
import SwiftUI

// MARK: - Pure helpers

struct TraceResult: Equatable {
    let ip: String
    let countryCode: String

    var isSupportedRegion: Bool {
        SupportedRegions.codes.contains(countryCode.uppercased())
    }
}

enum SupportedRegions {
    // Claude Help Center, "Where can I access Claude?", checked 2026-11-11.
    // https://support.claude.com/en/articles/8461763-where-can-i-access-claude
    // 177 listed location names map to 176 ISO 3166-1 alpha-2 codes;
    // "Herzegovina" and "Bosnia and Herzegovina" both map to BA.
    static let codes: Set<String> = Set("""
        AD AE AG AL AM AO AR AT AU AZ BA BB BD BE BF BG BH BI BJ BN BO BR BS BT BW BZ
        CA CG CH CI CL CM CO CR CV CY CZ DE DJ DK DM DO DZ EC EE EG ES FI FJ FM FR
        GA GB GD GE GH GM GN GQ GR GT GW GY HN HR HT HU ID IE IL IN IQ IS IT JM JO
        JP KE KG KH KI KM KN KR KW KZ LA LB LC LI LK LR LS LT LU LV MA MC MD ME MG
        MH MK MN MP MR MT MU MV MW MX MY MZ NA NE NG NL NO NP NR NZ OM PA PE PG PH
        PK PL PS PT PW PY QA RO RS RW SA SB SC SE SG SI SK SL SM SN SR ST SV SZ TD
        TG TH TJ TL TM TN TO TR TT TV TW TZ UA UG US UY UZ VA VC VN VU WS ZA ZM ZW
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}

enum TraceParser {
    static func parse(_ text: String) -> TraceResult? {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let line = String(rawLine)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        guard let ip = fields["ip"], !ip.isEmpty,
              let countryCode = fields["loc"], !countryCode.isEmpty else {
            return nil
        }
        return TraceResult(ip: ip, countryCode: countryCode.uppercased())
    }
}

enum VPNServiceParser {
    static func serviceNames(from output: String, excluding excludedName: String) -> [String] {
        var result: [String] = []
        for line in output.split(whereSeparator: \Character.isNewline) {
            let text = String(line)
            guard text.contains("(Connected)") || text.contains("(Connecting)") else { continue }
            if text.lowercased().contains("tailscale") { continue }
            guard let firstQuote = text.firstIndex(of: "\"") else { continue }
            let remainder = text[text.index(after: firstQuote)...]
            guard let secondQuote = remainder.firstIndex(of: "\"") else { continue }
            let name = String(remainder[..<secondQuote])
            if !name.isEmpty && name.caseInsensitiveCompare(excludedName) != .orderedSame {
                result.append(name)
            }
        }
        return Array(Set(result)).sorted()
    }
}

// MARK: - Command execution

struct CommandResult {
    let status: Int32
    let output: String
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output)
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        traceRequest.setValue("ClaudeLauncher/1.1", forHTTPHeaderField: "User-Agent")
        let (traceData, traceError) = synchronousRequest(traceRequest, timeout: 12)
        if let traceError { return .failure(traceError) }
        guard let traceData,
              let traceText = String(data: traceData, encoding: .utf8),
              let trace = TraceParser.parse(traceText) else {
            return .failure(NSError(domain: "ClaudePrep", code: 3, userInfo: [NSLocalizedDescriptionKey: "未能从 Claude 读取出口 IP 和地区"]))
        }

        return .success(IPCheckResult(trace: trace, countryName: countryName(for: trace.countryCode)))
    }

    private static func countryName(for code: String) -> String {
        Locale(identifier: "zh_CN").localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }
}

// MARK: - Workflow model

enum StepState {
    case idle
    case running
    case success
    case failure
}

struct WorkflowStep: Identifiable {
    let id: Int
    let title: String
    var detail: String
    var state: StepState
}

final class WorkflowModel: ObservableObject {
    @Published var steps: [WorkflowStep] = [
        WorkflowStep(id: 0, title: "关闭其他 VPN", detail: "Clash、Shadowrocket 等", state: .idle),
        WorkflowStep(id: 1, title: "启动并连接 Tailscale", detail: "等待 VPN 连通", state: .idle),
        WorkflowStep(id: 2, title: "检测出口 IP", detail: "由 App 直接检测", state: .idle),
        WorkflowStep(id: 3, title: "自动启动 Claude", detail: "仅支持地区自动启动", state: .idle)
    ]
    @Published var isRunning = false
    @Published var summary = "点击上方按钮，按顺序准备并启动"
    @Published var ipDisplay = "尚未检测"

    private let tailscaleName = "Tailscale"

    func runAll() {
        guard !isRunning else { return }
        reset()
        isRunning = true
        summary = "正在执行准备流程…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performFullWorkflow()
        }
    }

    func launchManually() {
        guard !isRunning else { return }
        reset()
        steps[0].detail = "手动启动：跳过此步骤"
        steps[1].detail = "手动启动：跳过此步骤"
        steps[3] = WorkflowStep(id: 3, title: "手动启动 Claude", detail: "等待出口检测结果", state: .idle)
        isRunning = true
        setStep(2, state: .running, detail: "正在检测 Claude 出口…")
        setStep(3, state: .idle, detail: "等待地区判断")
        updateSummary("手动启动前，正在重新检测出口 IP…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performIPCheckAndLaunch()
        }
    }

    private func reset() {
        steps = [
            WorkflowStep(id: 0, title: "关闭其他 VPN", detail: "Clash、Shadowrocket 等", state: .idle),
            WorkflowStep(id: 1, title: "启动并连接 Tailscale", detail: "等待 VPN 连通", state: .idle),
            WorkflowStep(id: 2, title: "检测出口 IP", detail: "由 App 直接检测", state: .idle),
            WorkflowStep(id: 3, title: "自动启动 Claude", detail: "仅支持地区自动启动", state: .idle)
        ]
        ipDisplay = "尚未检测"
    }

    private func performFullWorkflow() {
        setStep(0, state: .running, detail: "正在关闭其他 VPN…")
        switch closeOtherVPNs() {
        case .success(let closed):
            let detail = closed.isEmpty ? "未发现正在运行的其他 VPN" : "已处理：\(closed.joined(separator: "、"))"
            setStep(0, state: .success, detail: detail)
        case .failure(let error):
            setStep(0, state: .failure, detail: error.localizedDescription)
            setStep(1, state: .idle, detail: "上一步失败，未连接")
            setStep(2, state: .idle, detail: "尚未检测")
            setStep(3, state: .idle, detail: "尚未启动")
            finish("关闭其他 VPN 失败，已停止流程")
            return
        }

        setStep(1, state: .running, detail: "正在启动 Tailscale…")
        switch connectTailscale() {
        case .success(let message):
            setStep(1, state: .success, detail: message)
        case .failure(let error):
            setStep(1, state: .failure, detail: error.localizedDescription)
            setStep(2, state: .idle, detail: "Tailscale 连通后再检测")
            setStep(3, state: .idle, detail: "尚未启动")
            finish("Tailscale 没有连上，请在菜单栏确认后重试")
            return
        }

        setStep(2, state: .running, detail: "正在检测 Claude 出口…")
        performIPCheckAndLaunch()
    }

    private func closeOtherVPNs() -> Result<[String], Error> {
        let knownBundleIDs: Set<String> = [
            "io.github.clash-verge-rev.clash-verge-rev",
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
        let stillRunning = targeted.filter { !$0.isTerminated }.compactMap(\NSRunningApplication.localizedName)
        if !stillRunning.isEmpty {
            return .failure(NSError(domain: "ClaudeLauncher", code: 30, userInfo: [NSLocalizedDescriptionKey: "未能退出：\(stillRunning.joined(separator: "、"))"]))
        }

        let listResult = Shell.run("/usr/sbin/scutil", ["--nc", "list"])
        guard listResult.status == 0 else {
            return .failure(NSError(domain: "ClaudeLauncher", code: 31, userInfo: [NSLocalizedDescriptionKey: "无法读取 VPN 服务列表：\(listResult.output)"]))
        }
        let serviceNames = VPNServiceParser.serviceNames(from: listResult.output, excluding: tailscaleName)
        for service in serviceNames {
            let stopped = Shell.run("/usr/sbin/scutil", ["--nc", "stop", service], timeout: 8)
            guard stopped.status == 0 else {
                return .failure(NSError(domain: "ClaudeLauncher", code: 32, userInfo: [NSLocalizedDescriptionKey: "停止 VPN 服务 \(service) 失败：\(stopped.output)"]))
            }
        }

        let appNames = targeted.compactMap(\NSRunningApplication.localizedName)
        return .success(Array(Set(appNames + serviceNames)).sorted())
    }

    private func connectTailscale() -> Result<String, Error> {
        let appPath = "/Applications/Tailscale.app"
        guard FileManager.default.fileExists(atPath: appPath) else {
            return .failure(NSError(domain: "ClaudePrep", code: 10, userInfo: [NSLocalizedDescriptionKey: "没有找到 /Applications/Tailscale.app"]))
        }

        let current = Shell.run("/usr/sbin/scutil", ["--nc", "status", tailscaleName], timeout: 5)
        if current.output.split(whereSeparator: \Character.isNewline).first.map(String.init)?.caseInsensitiveCompare("Connected") == .orderedSame {
            return .success("Tailscale 已连接")
        }

        let opened = Shell.run("/usr/bin/open", [appPath], timeout: 8)
        guard opened.status == 0 else {
            return .failure(NSError(domain: "ClaudeLauncher", code: 11, userInfo: [NSLocalizedDescriptionKey: "打开 Tailscale 失败：\(opened.output)"]))
        }
        Thread.sleep(forTimeInterval: 1.5)
        let start = Shell.run("/usr/sbin/scutil", ["--nc", "start", tailscaleName], timeout: 10)

        for _ in 0..<25 {
            let status = Shell.run("/usr/sbin/scutil", ["--nc", "status", tailscaleName], timeout: 5)
            let firstLine = status.output.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? ""
            if firstLine.caseInsensitiveCompare("Connected") == .orderedSame {
                return .success("Tailscale 已连接")
            }
            Thread.sleep(forTimeInterval: 0.8)
        }
        let reason = start.status == 0 ? "等待 20 秒后仍未连接。请检查 Tailscale 是否已登录并选择出口节点。" : "启动 Tailscale 失败：\(start.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        return .failure(NSError(domain: "ClaudeLauncher", code: 12, userInfo: [NSLocalizedDescriptionKey: reason]))
    }

    private func performIPCheckAndLaunch() {
        switch IPDetector.detect() {
        case .failure(let error):
            setStep(2, state: .failure, detail: error.localizedDescription)
            setStep(3, state: .idle, detail: "未启动")
            finish("IP 检测失败，Claude App 没有启动")
        case .success(let result):
            let ipVersion = result.trace.ip.contains(":") ? "IPv6" : "IPv4"
            let display = "\(result.trace.ip)  ·  \(result.locationDisplay)  ·  \(ipVersion)"
            DispatchQueue.main.async { [weak self] in self?.ipDisplay = display }
            if result.trace.isSupportedRegion {
                setStep(2, state: .success, detail: "支持地区：\(result.locationDisplay)（\(result.trace.countryCode)）")
                setStep(3, state: .running, detail: "正在打开 Claude App…")
                switch launchClaudeApp() {
                case .success(let appPath):
                    setStep(3, state: .success, detail: "已启动：\(appPath)")
                    finish("出口位于支持地区，Claude App 已启动")
                case .failure(let error):
                    setStep(3, state: .failure, detail: error.localizedDescription)
                    finish("地区检测通过，但 Claude App 启动失败")
                }
            } else {
                setStep(2, state: .failure, detail: "当前为 \(result.locationDisplay)（\(result.trace.countryCode)），未列入支持地区")
                setStep(3, state: .idle, detail: "地区未通过：未启动")
                finish("当前出口未列入 Claude 支持地区，未启动")
            }
        }
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
        DispatchQueue.main.async { [weak self] in
            self?.summary = value
            self?.isRunning = false
        }
    }
}

// MARK: - SwiftUI view

private struct StepRow: View {
    let step: WorkflowStep

    private var color: Color {
        switch step.state {
        case .idle: return Color.secondary.opacity(0.55)
        case .running: return .orange
        case .success: return .green
        case .failure: return .red
        }
    }

    private var symbol: String {
        switch step.state {
        case .idle: return "\(step.id + 1)"
        case .running: return "…"
        case .success: return "✓"
        case .failure: return "!"
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
                    .foregroundStyle(step.state == .failure ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if step.state == .running {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 7)
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
                Button(action: model.runAll) {
                    HStack(spacing: 8) {
                        if model.isRunning { ProgressView().controlSize(.small) }
                        Image(systemName: model.isRunning ? "hourglass" : "play.fill")
                        Text(model.isRunning ? "正在执行…" : "一键启动")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.05, green: 0.55, blue: 0.58))
                .disabled(model.isRunning)
                .padding(.top, 14)
                .padding(.bottom, 9)

                ForEach(model.steps) { step in
                    StepRow(step: step)
                    if step.id < 3 { Divider().opacity(0.55) }
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

                Text("版本 \(appVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 5)
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
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 500),
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

// MARK: - Test and command-line modes

func runSelfTests() -> Int32 {
    var failures: [String] = []

    let us = TraceParser.parse("ip=8.8.8.8\nloc=US\nwarp=off\n")
    if us != TraceResult(ip: "8.8.8.8", countryCode: "US") || us?.isSupportedRegion != true {
        failures.append("US trace parsing")
    }
    let tw = TraceParser.parse("fl=x\nip=61.221.84.27\nloc=TW\n")
    if tw?.isSupportedRegion != true { failures.append("supported non-US region") }
    let cn = TraceParser.parse("ip=1.1.1.1\nloc=CN\n")
    if cn?.isSupportedRegion != false { failures.append("unsupported region gate") }
    if SupportedRegions.codes.count != 176 { failures.append("supported region list count") }
    if TraceParser.parse("ip=1.1.1.1\n") != nil { failures.append("missing loc rejection") }

    let sampleServices = """
    * (Disconnected) ABC VPN (com.test) \"Shadowrocket\" [VPN:com.test]
    * (Connected) GHI VPN (com.clash) \"Clash Verge\" [VPN:com.clash]
    * (Connected) DEF VPN (io.tailscale.ipn.macsys) \"Tailscale\" [VPN:io.tailscale.ipn.macsys]
    """
    if VPNServiceParser.serviceNames(from: sampleServices, excluding: "Tailscale") != ["Clash Verge"] {
        failures.append("VPN service parsing")
    }

    if failures.isEmpty {
        print("SELF-TEST PASS: trace parsing, supported-region gate, and VPN service parsing")
        return 0
    }
    print("SELF-TEST FAIL: \(failures.joined(separator: ", "))")
    return 1
}

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

