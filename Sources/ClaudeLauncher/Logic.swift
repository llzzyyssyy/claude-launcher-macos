import CoreFoundation
import Foundation

// Pure, side-effect-free helpers. The app target compiles this with main.swift.
// Self-tests cover the parsers so the VPN decisions can be checked without a Mac.

enum LauncherVersion {
    static let marketing = "1.1.3"
    static let userAgent = "ClaudeLauncher/1.1.3"
}

// MARK: - Trace and supported regions

struct TraceResult: Equatable {
    let ip: String
    let countryCode: String
    var timestamp: Date? = nil

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
        return TraceResult(
            ip: ip,
            countryCode: countryCode.uppercased(),
            timestamp: timestamp(from: fields["ts"])
        )
    }

    private static func timestamp(from raw: String?) -> Date? {
        guard let raw, let value = Double(raw), value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
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

// MARK: - Tailscale status

struct TailscaleExitNode: Equatable {
    let id: String
    let hostName: String
    let online: Bool
}

struct TailscaleStatus: Equatable {
    enum Blocker: Equatable {
        case notLoggedIn
        case needsMachineAuth
        case noExitNode
        case exitNodeOffline
        case backendStopped
        case notOnlineYet
        case starting
    }

    let backendState: String
    let selfOnline: Bool
    let wantRunning: Bool?
    let loggedOut: Bool?
    let exitNode: TailscaleExitNode?

    var isReady: Bool {
        backendState.caseInsensitiveCompare("Running") == .orderedSame
            && selfOnline
            && exitNode?.online == true
    }

    var blocker: Blocker? {
        if isReady { return nil }
        let state = backendState.lowercased()
        if state == "needslogin" || loggedOut == true {
            return .notLoggedIn
        }
        if state == "needsmachineauth" {
            return .needsMachineAuth
        }
        if state == "running" {
            if !selfOnline { return .notOnlineYet }
            if exitNode == nil { return .noExitNode }
            return .exitNodeOffline
        }
        if state == "starting" || state == "nostate" {
            return .starting
        }
        return .backendStopped
    }

    /// A bare `tailscale up` turns WantRunning back on without editing prefs.
    var shouldBringUp: Bool {
        if blocker == .notLoggedIn || blocker == .needsMachineAuth { return false }
        if wantRunning == false { return true }
        let state = backendState.lowercased()
        return state == "stopped" || state == "nostate"
    }
}

enum TailscaleStatusParser {
    static func parse(_ text: String) -> TailscaleStatus? {
        guard let object = JSONValues.object(from: text) else { return nil }
        guard let backend = JSONValues.string(object["BackendState"]), !backend.isEmpty else { return nil }
        let selfObject = object["Self"] as? [String: Any]
        let peers = JSONValues.peerList(object["Peer"])
        return TailscaleStatus(
            backendState: backend,
            selfOnline: JSONValues.bool(selfObject?["Online"]) ?? false,
            wantRunning: JSONValues.bool(object["WantRunning"]),
            loggedOut: JSONValues.bool(object["LoggedOut"]),
            exitNode: exitNode(in: object, peers: peers)
        )
    }

    private static func exitNode(in object: [String: Any], peers: [[String: Any]]) -> TailscaleExitNode? {
        if let status = object["ExitNodeStatus"] as? [String: Any] {
            let id = JSONValues.string(status["ID"]) ?? ""
            let online = JSONValues.bool(status["Online"]) ?? false
            return TailscaleExitNode(id: id, hostName: hostName(id: id, peers: peers), online: online)
        }
        guard let selected = peers.first(where: { JSONValues.bool($0["ExitNode"]) == true }) else {
            return nil
        }
        return TailscaleExitNode(
            id: JSONValues.string(selected["ID"]) ?? "",
            hostName: hostName(of: selected),
            online: JSONValues.bool(selected["Online"]) ?? false
        )
    }

    private static func hostName(id: String, peers: [[String: Any]]) -> String {
        if !id.isEmpty, let match = peers.first(where: { JSONValues.string($0["ID"]) == id }) {
            return hostName(of: match)
        }
        if let selected = peers.first(where: { JSONValues.bool($0["ExitNode"]) == true }) {
            return hostName(of: selected)
        }
        return ""
    }

    private static func hostName(of peer: [String: Any]) -> String {
        if let host = JSONValues.string(peer["HostName"]), !host.isEmpty { return host }
        guard let dns = JSONValues.string(peer["DNSName"]), !dns.isEmpty else { return "" }
        return dns.split(separator: ".").first.map(String.init) ?? dns
    }
}

struct TailscalePrefs: Equatable {
    let wantRunning: Bool?
    let loggedOut: Bool?
    let exitNodeID: String
    let exitNodeIP: String
    let autoExitNode: String

    var hasExitNode: Bool {
        !exitNodeID.isEmpty || !exitNodeIP.isEmpty || !autoExitNode.isEmpty
    }
}

enum TailscalePrefsParser {
    /// Reads only the running-state and exit-node fields. The prefs payload also
    /// contains node private keys; callers must not log the raw text.
    static func parse(_ text: String) -> TailscalePrefs? {
        guard let object = JSONValues.object(from: text) else { return nil }
        guard object["WantRunning"] != nil || object["ExitNodeID"] != nil || object["LoggedOut"] != nil else {
            return nil
        }
        return TailscalePrefs(
            wantRunning: JSONValues.bool(object["WantRunning"]),
            loggedOut: JSONValues.bool(object["LoggedOut"]),
            exitNodeID: JSONValues.string(object["ExitNodeID"]) ?? "",
            exitNodeIP: JSONValues.string(object["ExitNodeIP"]) ?? "",
            autoExitNode: JSONValues.string(object["AutoExitNode"]) ?? ""
        )
    }
}

enum TailscaleUpSuggestion {
    /// Arguments from the CLI's "mention all non-default flags" hint.
    /// A bare `tailscale up` keeps the saved exit node on current Tailscale
    /// versions. Older builds print the full command instead of applying defaults;
    /// re-running that command preserves the exit node. `--reset` is rejected
    /// because it would drop those prefs.
    static func arguments(from output: String) -> [String]? {
        guard output.localizedCaseInsensitiveContains("non-default") else { return nil }
        let lines = output.split(whereSeparator: \Character.isNewline).map(String.init)
        // The error prose also contains the words "tailscale up". Only the
        // suggested command is followed by flags (or a bare command plus
        // continuation lines that start with --).
        guard let index = lines.firstIndex(where: { line in
            guard let range = line.range(of: "tailscale up") else { return false }
            let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return rest.hasPrefix("--") || rest.isEmpty
        }) else { return nil }
        var command = lines[index]
        var cursor = index + 1
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--") {
                command += " " + trimmed
                cursor += 1
            } else {
                break
            }
        }
        guard let range = command.range(of: "tailscale up") else { return nil }
        let rest = command[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let args = splitArguments(rest)
        if args.isEmpty { return nil }
        if args.contains(where: { $0 == "--reset" || $0.hasPrefix("--reset=") }) { return nil }
        return args
    }

    static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

enum TailscaleMessages {
    static let appMissing = "没有找到 /Applications/Tailscale.app"
    static let cliMissing = "找不到 tailscale 命令。请确认已安装 Tailscale（/usr/local/bin/tailscale、Homebrew，或 App 内的命令行）"
    static let serviceUnreachable = "连不上 Tailscale 本地服务。请打开 Tailscale，并在系统提示时允许它的 VPN 配置"

    static func success(_ status: TailscaleStatus) -> String {
        let name = status.exitNode?.hostName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { return "Tailscale 已运行，出口节点在线" }
        return "Tailscale 已运行，出口节点 \(name) 在线"
    }

    static func failure(blocker: TailscaleStatus.Blocker, hasSavedExitNode: Bool) -> String {
        switch blocker {
        case .notLoggedIn:
            return "Tailscale 未登录。请在菜单栏的 Tailscale 里登录后重试"
        case .needsMachineAuth:
            return "这台 Mac 还没通过 Tailscale 的设备批准。请在管理后台允许后重试"
        case .noExitNode:
            if hasSavedExitNode {
                return "已保存出口节点，但当前没有用上。请在 Tailscale 菜单栏重新选择出口节点后重试"
            }
            return "未设置出口节点。请在 Tailscale 菜单栏选择出口节点后重试"
        case .exitNodeOffline:
            return "出口节点当前离线。请在 Tailscale 里换一个在线的出口节点后重试"
        case .backendStopped:
            return "Tailscale 后端仍是停止状态。系统 VPN 显示已连接时，后端也可能没在运行。请打开菜单栏里的 Tailscale 后重试"
        case .notOnlineYet:
            return "Tailscale 后端已启动，但这台 Mac 还没有上线"
        case .starting:
            return "Tailscale 仍在启动。请确认菜单栏里已登录并选择了出口节点后重试"
        }
    }

    static func upFailed(_ output: String) -> String {
        if output.localizedCaseInsensitiveContains("non-default") {
            return "tailscale up 要求带上全部已有参数，但没有解析到可原样执行的命令。请在菜单栏手动打开连接"
        }
        let snippet = output
            .split(whereSeparator: \Character.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let redacted = LogRedactor.redact(snippet)
        if redacted.isEmpty { return "tailscale up 失败" }
        return "tailscale up 失败：\(String(redacted.prefix(160)))"
    }
}

// MARK: - Clash controller and route audit

enum ClashProcess {
    static func controllerSockets(fromPS output: String) -> [String] {
        var paths: [String] = []
        for raw in output.split(whereSeparator: \Character.isNewline) {
            let line = String(raw)
            let lower = line.lowercased()
            guard lower.contains("mihomo") || lower.contains("clash") || lower.contains("verge") else { continue }
            paths.append(contentsOf: sockets(inCommand: line))
        }
        return unique(paths)
    }

    static func sockets(inCommand command: String) -> [String] {
        let tokens = TailscaleUpSuggestion.splitArguments(command)
        var paths: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "-ext-ctl-unix" || token == "--ext-ctl-unix" {
                if index + 1 < tokens.count { paths.append(tokens[index + 1]) }
                index += 2
                continue
            }
            for prefix in ["-ext-ctl-unix=", "--ext-ctl-unix="] where token.hasPrefix(prefix) {
                paths.append(String(token.dropFirst(prefix.count)))
            }
            index += 1
        }
        return paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

enum ClashYAML {
    static func externalControllerUnix(in yaml: String) -> String? {
        scalar(named: "external-controller-unix", in: yaml)
    }

    static func secret(in yaml: String) -> String? {
        scalar(named: "secret", in: yaml)
    }

    private static func scalar(named key: String, in yaml: String) -> String? {
        for raw in yaml.split(whereSeparator: \Character.isNewline) {
            let line = String(raw)
            guard !line.hasPrefix(" ") && !line.hasPrefix("\t") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare(key) == .orderedSame else { continue }
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#"), value[value.startIndex..<hash].last == " " || value.hasPrefix("#") {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if value.isEmpty || value == "null" || value == "~" { return nil }
            return value
        }
        return nil
    }
}

struct ClashRuntime: Equatable {
    let tunEnabled: Bool?
    let ports: Set<Int>
}

enum ClashRuntimeParser {
    static let disableTunBody = #"{"tun":{"enable":false}}"#

    static func parse(_ json: String) -> ClashRuntime? {
        guard let object = JSONValues.object(from: json) else { return nil }
        let tun = (object["tun"] as? [String: Any]).flatMap { JSONValues.bool($0["enable"]) }
        var ports: Set<Int> = []
        for key in ["mixed-port", "port", "socks-port", "redir-port"] {
            if let port = JSONValues.int(object[key]), (1...65535).contains(port) {
                ports.insert(port)
            }
        }
        return ClashRuntime(tunEnabled: tun, ports: ports)
    }
}

enum HTTPMessage {
    static func split(_ raw: String) -> (status: Int, body: String)? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let header: String
        let body: String
        if let marker = normalized.range(of: "\n\n") {
            header = String(normalized[..<marker.lowerBound])
            body = String(normalized[marker.upperBound...])
        } else {
            header = normalized
            body = ""
        }
        guard let first = header.split(separator: "\n", maxSplits: 1).first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        return (status, body)
    }
}

enum NetworkAudit {
    /// Clash Meta's default TUN addresses: 198.18.0.0/15 and fdfe:dcba:9876::/64.
    static func hasClashCapture(in text: String) -> Bool {
        if text.lowercased().contains("fdfe:dcba:9876") { return true }
        return ipv4Tokens(in: text).contains(where: isClashTunIPv4)
    }

    static func isClashTunIPv4(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        return first == 198 && (second == 18 || second == 19)
    }

    static func ipv4Tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if isIPv4(current) { tokens.append(current) }
            current = ""
        }
        for character in text {
            if character.isNumber || character == "." {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    static func isIPv4(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value), !part.isEmpty else { return false }
            return true
        }
    }
}

enum NetworkServiceList {
    static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \Character.isNewline).compactMap { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("An asterisk") || line.hasPrefix("*") { return nil }
            return line
        }
    }
}

struct ProxySetting: Equatable {
    let enabled: Bool
    let server: String
    let port: Int
}

enum SystemProxyParser {
    static func parse(_ output: String) -> ProxySetting? {
        var enabled: Bool?
        var server = ""
        var port: Int?
        for raw in output.split(whereSeparator: \Character.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if let value = value(after: "Enabled:", in: line) {
                enabled = value.caseInsensitiveCompare("Yes") == .orderedSame
            } else if let value = value(after: "Server:", in: line) {
                server = value
            } else if let value = value(after: "Port:", in: line) {
                port = Int(value)
            }
        }
        guard let enabled, let port else { return nil }
        return ProxySetting(enabled: enabled, server: server, port: port)
    }

    static func isLoopback(_ server: String) -> Bool {
        let host = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
}

enum ClashMessages {
    static let tunRemains = "仍被其他 VPN 拦截：检测到 Clash 的 198.18.x 网卡或默认路由。服务模式只关窗口不会停内核，请在 Clash Verge Rev 里关闭 TUN 后重试"
    static func proxyRemains(server: String, port: Int, service: String) -> String {
        "系统代理仍指向本机 \(server):\(port)（\(service)）。请在系统设置的网络代理里关掉网页、安全网页和 SOCKS 代理后重试"
    }
}

// MARK: - Extra checks (warnings only)

struct DNSResolver: Equatable {
    var domain: String = ""
    var nameservers: [String] = []
    var scoped: Bool = false
}

enum DNSAudit {
    static func parse(_ output: String) -> [DNSResolver] {
        var resolvers: [DNSResolver] = []
        var current: DNSResolver?
        func flush() {
            if let current { resolvers.append(current) }
            current = nil
        }
        for raw in output.split(whereSeparator: \Character.isNewline) {
            let trimmed = String(raw).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("resolver #") {
                flush()
                current = DNSResolver()
                continue
            }
            guard var item = current, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("nameserver[") {
                item.nameservers.append(String(value))
            } else if key == "domain" {
                item.domain = String(value)
            } else if key == "if_index" {
                item.scoped = true
            }
            current = item
        }
        flush()
        return resolvers
    }

    static func warnings(resolvers: [DNSResolver], egressCountry: String) -> [String] {
        guard egressCountry.uppercased() != "CN" else { return [] }
        let general = resolvers.filter { $0.domain.isEmpty || $0.domain == "." }
        let unscoped = general.filter { !$0.scoped }
        let chosen = unscoped.isEmpty ? general : unscoped
        let servers = unique(chosen.flatMap(\.nameservers).map(normalize))
        if servers.isEmpty { return [] }
        let domestic = servers.filter(isDomestic)
        if !domestic.isEmpty {
            return ["系统 DNS 含中国大陆解析器 \(list(domestic))，出口在国外时域名查询可能暴露真实网络"]
        }
        let tailscale = servers.contains(where: isTailscale)
        let local = servers.filter { isLocal($0) && !isTailscale($0) }
        if !tailscale && !local.isEmpty {
            return ["系统 DNS 指向本地或局域网 \(list(local))，出口在国外时查询可能仍由运营商解析"]
        }
        return []
    }

    private static func normalize(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let zone = trimmed.firstIndex(of: "%") {
            return String(trimmed[..<zone])
        }
        return trimmed
    }

    static func isDomestic(_ address: String) -> Bool {
        domesticResolvers.contains(normalize(address))
    }

    static func isTailscale(_ address: String) -> Bool {
        let value = normalize(address)
        if value == "100.100.100.100" { return true }
        if value.hasPrefix("fd7a:115c:a1e0:") { return true }
        return isCGNAT(value)
    }

    static func isLocal(_ address: String) -> Bool {
        let value = normalize(address)
        if value == "127.0.0.1" || value == "::1" || value == "localhost" { return true }
        if value.hasPrefix("fe80:") { return true }
        guard let parts = ipv4Parts(value) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }

    private static func isCGNAT(_ address: String) -> Bool {
        guard let parts = ipv4Parts(address) else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func ipv4Parts(_ address: String) -> [Int]? {
        guard NetworkAudit.isIPv4(address) else { return nil }
        return address.split(separator: ".").compactMap { Int($0) }
    }

    private static func list(_ values: [String]) -> String {
        if values.count <= 3 { return values.joined(separator: "、") }
        return values.prefix(3).joined(separator: "、") + " 等"
    }

    private static let domesticResolvers: Set<String> = [
        "114.114.114.114", "114.114.115.115",
        "223.5.5.5", "223.6.6.6",
        "119.29.29.29", "119.28.28.28", "182.254.116.116", "182.254.118.118",
        "180.76.76.76",
        "1.2.4.8", "210.2.4.8",
        "101.226.4.6", "218.30.118.6",
        "202.96.128.86", "202.96.134.133",
        "202.106.0.20", "202.106.196.115",
        "221.179.38.7",
        "2400:3200::1", "2400:3200:baba::1"
    ]
}

enum TimezoneAudit {
    static func warning(countryCode: String, countryName: String, gmtOffsetMinutes: Int, identifier: String) -> String? {
        let code = countryCode.uppercased()
        guard let allowed = offsets[code] else { return nil }
        if allowed.contains(gmtOffsetMinutes) { return nil }
        let place = countryName.isEmpty ? code : countryName
        return "系统时区 \(identifier)（\(format(gmtOffsetMinutes))）与出口地区 \(place) 不一致"
    }

    static func covers(_ code: String) -> Bool {
        offsets[code.uppercased()] != nil
    }

    static var coveredCount: Int { offsets.count }

    static func format(_ minutes: Int) -> String {
        let sign = minutes >= 0 ? "+" : "-"
        let absolute = abs(minutes)
        let hours = absolute / 60
        let remainder = absolute % 60
        if remainder == 0 { return "UTC\(sign)\(hours)" }
        return String(format: "UTC%@%d:%02d", sign, hours, remainder)
    }

    // Offsets in minutes, including daylight-saving variants. Used only to warn.
    // A missing country produces no warning rather than a guess.
    private static let offsets: [String: Set<Int>] = {
        var map: [String: Set<Int>] = [:]
        func set(_ codes: String, _ minutes: Int...) {
            let values = Set(minutes)
            for code in codes.split(whereSeparator: \.isWhitespace) {
                map[String(code)] = values
            }
        }
        set("AD AL AT BA BE CH CZ DE DK FR HR HU IT LI LU MC ME MK MT NL NO PL RS SE SI SK SM VA", 60, 120)
        set("BG CY EE EG FI GR IL LB LT LV MD PS RO UA", 120, 180)
        set("GB IE", 0, 60)
        set("PT", -60, 0, 60)
        set("ES", 0, 60, 120)
        set("IS MA", 0, 60)
        set("BF CI GH GM GN GW LR MR SL SN ST TG", 0)
        set("AO BJ CG CM DZ GA GQ NE NG TD TN", 60)
        set("BI BW LS MW MZ NA RW SZ ZA ZM ZW", 120)
        set("BH DJ IQ JO KE KM KW MG QA SA TR TZ UG", 180)
        set("AE AM AZ GE MU OM SC", 240)
        set("MV PK TJ TM UZ", 300)
        set("KZ", 300, 360)
        set("BD BT KG", 360)
        set("IN LK", 330)
        set("NP", 345)
        set("ID", 420, 480, 540)
        set("KH LA TH VN", 420)
        set("MN", 420, 480)
        set("BN MY PH SG TW", 480)
        set("JP KR PW TL", 540)
        set("AU", 480, 570, 600, 630, 660)
        set("FM PG", 600, 660)
        set("MP", 600)
        set("SB VU", 660)
        set("FJ", 720, 780)
        set("KI", 720, 780, 840)
        set("MH NR TV", 720)
        set("NZ", 720, 765, 780, 825)
        set("TO WS", 780)
        set("US", -600, -540, -480, -420, -360, -300, -240)
        set("CA", -480, -420, -360, -300, -240, -210, -150)
        set("MX", -480, -420, -360, -300)
        set("BR", -300, -240, -180, -120)
        set("CL", -360, -300, -240, -180)
        set("EC", -360, -300)
        set("PY", -240, -180)
        set("BS HT", -300, -240)
        set("AG BB BO DM DO GD GY KN LC TT VC", -240)
        set("AR SR UY", -180)
        set("CO JM PA PE", -300)
        set("BZ CR GT HN SV", -360)
        set("CV", -60)
        return map
    }()
}

enum ExtraCheckReport {
    static func warnings(
        trace: TraceResult,
        countryName: String,
        now: Date,
        timeZoneID: String,
        gmtOffsetMinutes: Int,
        dnsOutput: String,
        ipv6Country: String?
    ) -> [String] {
        var messages: [String] = []
        if let timezone = TimezoneAudit.warning(
            countryCode: trace.countryCode,
            countryName: countryName,
            gmtOffsetMinutes: gmtOffsetMinutes,
            identifier: timeZoneID
        ) {
            messages.append(timezone)
        }
        if let clock = clockWarning(trace: trace, now: now) {
            messages.append(clock)
        }
        messages.append(contentsOf: DNSAudit.warnings(resolvers: DNSAudit.parse(dnsOutput), egressCountry: trace.countryCode))
        if let ipv6 = ipv6Warning(primary: trace.countryCode, ipv6: ipv6Country) {
            messages.append(ipv6)
        }
        return messages
    }

    static func clockWarning(trace: TraceResult, now: Date) -> String? {
        guard let timestamp = trace.timestamp else { return nil }
        let delta = abs(now.timeIntervalSince(timestamp))
        guard delta > 5 * 60 else { return nil }
        let minutes = max(1, Int((delta / 60).rounded()))
        return "系统时间与 Claude 站点时间相差约 \(minutes) 分钟"
    }

    static func ipv6Warning(primary: String, ipv6: String?) -> String? {
        guard let ipv6, !ipv6.isEmpty else { return nil }
        guard ipv6.caseInsensitiveCompare(primary) != .orderedSame else { return nil }
        return "IPv6 出口在 \(ipv6.uppercased())，与主出口 \(primary.uppercased()) 不一致，可能绕过了出口节点"
    }
}

// MARK: - Log redaction

enum LogRedactor {
    static func redact(_ text: String) -> String {
        var value = text
        let rules: [(String, String)] = [
            (#"privkey:[A-Za-z0-9]+"#, "privkey:[redacted]"),
            (#"tskey-[A-Za-z0-9-]+"#, "tskey-[redacted]"),
            (#"authkey-[A-Za-z0-9-]+"#, "authkey-[redacted]"),
            (#"(?i)(--auth-key(?:=|\s+))\S+"#, "$1[redacted]"),
            (#"(?i)(Bearer\s+)\S+"#, "$1[redacted]"),
            (#"(?i)(\"PrivateNodeKey\"\s*:\s*\")[^\"]*\""#, "$1[redacted]\""),
            (#"(?i)(\"OldPrivateNodeKey\"\s*:\s*\")[^\"]*\""#, "$1[redacted]\""),
            (#"(?i)(\"NetworkLockKey\"\s*:\s*\")[^\"]*\""#, "$1[redacted]\""),
            (#"(?i)(\"secret\"\s*:\s*\")[^\"]*\""#, "$1[redacted]\""),
            (#"(?im)^(secret\s*:\s*)\S.*$"#, "$1[redacted]"),
            (#"https://login\.tailscale\.com/\S+"#, "https://login.tailscale.com/[redacted]")
        ]
        for (pattern, template) in rules {
            value = replace(value, pattern: pattern, template: template)
        }
        return value
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

// MARK: - JSON helpers

enum JSONValues {
    static func object(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        let tail = String(text[start...])
        if let parsed = parse(tail) { return parsed }
        guard let end = text.lastIndex(of: "}") , end >= start else { return nil }
        return parse(String(text[start...end]))
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, !isJSONBool(number) {
            return number.stringValue
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isJSONBool(number) else { return nil }
        return number.boolValue
    }

    static func int(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        if let number = value as? NSNumber, !isJSONBool(number) {
            return number.intValue
        }
        return nil
    }

    private static func isJSONBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func peerList(_ value: Any?) -> [[String: Any]] {
        guard let map = value as? [String: Any] else { return [] }
        return map.values.compactMap { $0 as? [String: Any] }
    }

    private static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private func unique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for value in values where seen.insert(value).inserted {
        result.append(value)
    }
    return result
}

// MARK: - Self-test

func runSelfTests() -> Int32 {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String) {
        if !condition { failures.append(name) }
    }

    let us = TraceParser.parse("ip=8.8.8.8\nloc=US\nwarp=off\n")
    expect(us == TraceResult(ip: "8.8.8.8", countryCode: "US"), "US trace parsing")
    expect(us?.isSupportedRegion == true, "US region gate")
    let tw = TraceParser.parse("fl=x\nip=61.221.84.27\nloc=TW\n")
    expect(tw?.isSupportedRegion == true, "supported non-US region")
    let cn = TraceParser.parse("ip=1.1.1.1\nloc=CN\n")
    expect(cn?.isSupportedRegion == false, "unsupported region gate")
    expect(SupportedRegions.codes.count == 176, "supported region list count")
    expect(TraceParser.parse("ip=1.1.1.1\n") == nil, "missing loc rejection")
    let stamped = TraceParser.parse("ip=1.1.1.1\nloc=US\nts=1700000000.5\n")
    expect(stamped?.timestamp == Date(timeIntervalSince1970: 1700000000.5), "trace timestamp")

    let sampleServices = """
    * (Disconnected) ABC VPN (com.test) \"Shadowrocket\" [VPN:com.test]
    * (Connected) GHI VPN (com.clash) \"Clash Verge\" [VPN:com.clash]
    * (Connected) DEF VPN (io.tailscale.ipn.macsys) \"Tailscale\" [VPN:io.tailscale.ipn.macsys]
    """
    expect(VPNServiceParser.serviceNames(from: sampleServices, excluding: "Tailscale") == ["Clash Verge"], "VPN service parsing")

    let runningJSON = """
    notice
    {"BackendState":"Running","WantRunning":true,"Self":{"Online":true,"HostName":"mbp"},
     "ExitNodeStatus":{"ID":"n1","Online":true},
     "Peer":{"nodekey:abc":{"ID":"n1","HostName":"exit-a","Online":true,"ExitNode":true,"ExitNodeOption":true}}}
    """
    let running = TailscaleStatusParser.parse(runningJSON)
    expect(running?.isReady == true, "ready when backend, self, and exit node are up")
    expect(running?.exitNode?.hostName == "exit-a", "exit node hostname")
    expect(running?.shouldBringUp == false, "ready node is not brought up again")

    let stopped = TailscaleStatusParser.parse(#"{"BackendState":"Stopped","WantRunning":false,"Self":{"Online":false}}"#)
    expect(stopped?.isReady == false, "stopped is not ready")
    expect(stopped?.shouldBringUp == true, "stopped backend should be brought up")
    expect(stopped?.blocker == .backendStopped, "stopped blocker")

    let needsLogin = TailscaleStatusParser.parse(#"{"BackendState":"NeedsLogin","Self":{"Online":false}}"#)
    expect(needsLogin?.blocker == .notLoggedIn, "needs login")
    expect(needsLogin?.shouldBringUp == false, "login is not an up command")

    let noExit = TailscaleStatusParser.parse(#"{"BackendState":"Running","Self":{"Online":true},"Peer":{}}"#)
    expect(noExit?.blocker == .noExitNode, "running without exit node")

    let offline = TailscaleStatusParser.parse(#"{"BackendState":"Running","Self":{"Online":true},"ExitNodeStatus":{"ID":"n9","Online":false}}"#)
    expect(offline?.blocker == .exitNodeOffline, "exit node offline")

    let peerOnly = TailscaleStatusParser.parse(#"{"BackendState":"Running","Self":{"Online":true},"Peer":{"k":{"ID":"n2","DNSName":"node.example.ts.net.","Online":true,"ExitNode":true}}}"#)
    expect(peerOnly?.isReady == true && peerOnly?.exitNode?.hostName == "node", "peer exit node without status object")

    let notOnline = TailscaleStatusParser.parse(#"{"BackendState":"Running","Self":{"Online":false},"ExitNodeStatus":{"ID":"n1","Online":true}}"#)
    expect(notOnline?.blocker == .notOnlineYet, "self offline")

    let prefs = TailscalePrefsParser.parse(#"""
    {"WantRunning":false,"LoggedOut":false,"ExitNodeID":"n1","ExitNodeIP":"","AutoExitNode":"",
     "Config":{"PrivateNodeKey":"privkey:abcdef0123456789"}}
    """#)
    expect(prefs?.hasExitNode == true && prefs?.wantRunning == false && prefs?.loggedOut == false, "prefs exit node")
    expect(prefs?.exitNodeID == "n1", "prefs does not swap in the private key")

    let suggestion = """
    Error: changing settings via 'tailscale up' requires mentioning all
    non-default flags. To proceed, either re-run your command with --reset or
    use the command below to explicitly mention the current value of
    all non-default settings:

    \ttailscale up --accept-routes --exit-node=100.64.1.2 --exit-node-allow-lan-access=true
    """
    expect(
        TailscaleUpSuggestion.arguments(from: suggestion) == ["--accept-routes", "--exit-node=100.64.1.2", "--exit-node-allow-lan-access=true"],
        "non-default flag suggestion"
    )
    expect(TailscaleUpSuggestion.arguments(from: "tailscale up --reset") == nil, "ignore reset suggestion")
    expect(TailscaleUpSuggestion.arguments(from: "Success.") == nil, "ordinary output has no suggestion")

    let captured = """
    utun8: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST>
    \tinet 198.18.0.1 --> 198.18.0.1 netmask 0xfffffffc
    default            198.18.0.2         UGScg             utun8
    """
    expect(NetworkAudit.hasClashCapture(in: captured), "clash tun address")
    expect(!NetworkAudit.hasClashCapture(in: "inet 100.101.102.103\ndefault 192.168.1.1 UGSc en0\n"), "tailscale and lan routes are not clash")
    expect(NetworkAudit.hasClashCapture(in: "gateway: 198.19.0.2"), "clash fake-ip /15 gateway")
    expect(NetworkAudit.hasClashCapture(in: "inet6 fdfe:dcba:9876::1 prefixlen 64"), "clash default ipv6 tun")

    let dnsMagic = """
    resolver #1
      nameserver[0] : 100.100.100.100
    resolver #2
      nameserver[0] : 192.168.1.1
      if_index : 12 (en0)
    """
    expect(DNSAudit.warnings(resolvers: DNSAudit.parse(dnsMagic), egressCountry: "US").isEmpty, "magicDNS is not a leak")
    let dnsDomestic = "resolver #1\n  nameserver[0] : 114.114.114.114\n"
    expect(!DNSAudit.warnings(resolvers: DNSAudit.parse(dnsDomestic), egressCountry: "US").isEmpty, "domestic resolver warns")
    expect(DNSAudit.warnings(resolvers: DNSAudit.parse(dnsDomestic), egressCountry: "CN").isEmpty, "no dns warning for CN egress")
    let dnsLan = "resolver #1\n  nameserver[0] : 192.168.1.1\n"
    expect(!DNSAudit.warnings(resolvers: DNSAudit.parse(dnsLan), egressCountry: "JP").isEmpty, "lan resolver warns")
    let dnsPublic = "resolver #1\n  nameserver[0] : 8.8.8.8\n"
    expect(DNSAudit.warnings(resolvers: DNSAudit.parse(dnsPublic), egressCountry: "US").isEmpty, "public resolver is not a domestic leak")

    expect(TimezoneAudit.warning(countryCode: "US", countryName: "美国", gmtOffsetMinutes: 480, identifier: "Asia/Shanghai") != nil, "timezone mismatch")
    expect(TimezoneAudit.warning(countryCode: "US", countryName: "美国", gmtOffsetMinutes: -420, identifier: "America/Los_Angeles") == nil, "US daylight offset")
    expect(TimezoneAudit.warning(countryCode: "JP", countryName: "日本", gmtOffsetMinutes: 540, identifier: "Asia/Tokyo") == nil, "Japan offset")
    expect(TimezoneAudit.warning(countryCode: "NP", countryName: "尼泊尔", gmtOffsetMinutes: 345, identifier: "Asia/Kathmandu") == nil, "Nepal half hour")
    expect(TimezoneAudit.coveredCount == SupportedRegions.codes.count, "timezone map size")
    expect(SupportedRegions.codes.allSatisfy { TimezoneAudit.covers($0) }, "timezone map covers supported regions")

    let skewed = TraceResult(ip: "1.1.1.1", countryCode: "US", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    expect(ExtraCheckReport.clockWarning(trace: skewed, now: Date(timeIntervalSince1970: 1_700_000_000 + 600)) != nil, "clock skew warns")
    expect(ExtraCheckReport.clockWarning(trace: skewed, now: Date(timeIntervalSince1970: 1_700_000_030)) == nil, "small skew is quiet")
    expect(ExtraCheckReport.ipv6Warning(primary: "US", ipv6: "CN") != nil, "ipv6 mismatch")
    expect(ExtraCheckReport.ipv6Warning(primary: "US", ipv6: nil) == nil, "no ipv6 is not a leak")
    expect(ExtraCheckReport.ipv6Warning(primary: "US", ipv6: "us") == nil, "matching ipv6")

    let http = HTTPMessage.split("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
    expect(http?.status == 204 && http?.body.isEmpty == true, "http 204")
    let configs = ClashRuntimeParser.parse(#"{"tun":{"enable":true},"mixed-port":7897,"port":7899,"socks-port":7898}"#)
    expect(configs?.tunEnabled == true && configs?.ports == [7897, 7898, 7899], "clash runtime ports")

    let yaml = """
    mixed-port: 7897
    secret: "set-your-secret"
    external-controller-unix: /var/run/clash-verge-service/users/501/verge-mihomo.sock
      secret: nested-should-ignore
    """
    expect(ClashYAML.secret(in: yaml) == "set-your-secret", "yaml secret")
    expect(ClashYAML.externalControllerUnix(in: yaml)?.hasSuffix("verge-mihomo.sock") == true, "yaml socket")

    let ps = #"501 verge-mihomo -d /Library/Application Support/clash -ext-ctl-unix /var/run/clash-verge-service/users/501/verge-mihomo.sock"#
    expect(
        ClashProcess.controllerSockets(fromPS: ps) == ["/var/run/clash-verge-service/users/501/verge-mihomo.sock"],
        "ps ext-ctl socket"
    )

    let proxy = """
    Enabled: Yes
    Server: 127.0.0.1
    Port: 7897
    Authenticated Proxy Enabled: 0
    """
    let parsedProxy = SystemProxyParser.parse(proxy)
    expect(parsedProxy == ProxySetting(enabled: true, server: "127.0.0.1", port: 7897), "system proxy parse")
    expect(SystemProxyParser.isLoopback("localhost"), "loopback host")
    let services = NetworkServiceList.parse("An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Ethernet\nUSB LAN\n")
    expect(services == ["Wi-Fi", "USB LAN"], "enabled network services")

    let leaked = LogRedactor.redact(#"""
    {"PrivateNodeKey":"privkey:abcdef0123456789","secret":"hide-me"}
    Authorization: Bearer sup3rsecret
    secret: hide-me
    --auth-key=tskey-auth-abc
    https://login.tailscale.com/a/secret-token
    Tailscale 已运行
    """#)
    expect(!leaked.contains("abcdef0123456789"), "redact private node key")
    expect(!leaked.contains("hide-me"), "redact secret")
    expect(!leaked.contains("sup3rsecret"), "redact bearer")
    expect(!leaked.contains("tskey-auth-abc"), "redact auth key")
    expect(!leaked.contains("secret-token"), "redact tailscale login url")
    expect(leaked.contains("Tailscale 已运行"), "keep ordinary log text")

    if failures.isEmpty {
        print("SELF-TEST PASS: trace, regions, VPN list, tailscale status, clash audit, DNS, timezone, redaction")
        return 0
    }
    print("SELF-TEST FAIL: \(failures.joined(separator: ", "))")
    return 1
}
