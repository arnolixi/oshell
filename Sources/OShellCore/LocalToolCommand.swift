// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// A direct executable plus arguments, not a shell program. No expansion or eval.
public struct LocalToolCommand: Equatable {
    public let name: String
    public let arguments: [String]
    private let explicitPath: String?
    public static let groups: [(title: String, names: [String])] = [
        ("连通与路径", ["ping", "ping6", "traceroute", "traceroute6", "mtr"]),
        ("DNS 查询", ["dig", "nslookup", "host", "dscacheutil"]),
        ("端口与连接", ["nc", "telnet", "ssh", "netstat", "lsof"]),
        ("HTTP / TLS", ["curl", "openssl"]),
        ("本机网络", ["ifconfig", "ipconfig", "route", "arp", "ndp", "scutil", "networksetup"]),
        ("抓包与扫描", ["tcpdump", "nmap"]),
        ("带宽与质量", ["networkQuality", "iperf3"]),
        ("注册信息", ["whois"])
    ]
    public static var names: [String] { groups.flatMap(\.names) }
    public static var help: String {
        "本机网络工具：\r\n" + groups.map { $0.title + "：" + $0.names.joined(separator: "、") }.joined(separator: "\r\n") +
        "\r\ntools 查看安装状态与路径。支持参数和引号，不解析管道、重定向或变量。Ctrl+C 中断当前操作；exit / quit 关闭标签，⇧⌘R 重连原会话。"
    }
    public static func availability() -> String {
        names.map { name in
            let path = try? parse(name).executable()
            return name + "  " + (path ?? "未安装 / 未找到")
        }.joined(separator: "\r\n")
    }
    public var permitsManagedInput: Bool {
        ["ping", "ping6", "traceroute", "traceroute6", "mtr", "dig", "host", "dscacheutil", "netstat", "lsof", "ifconfig", "ipconfig", "route", "arp", "ndp", "networksetup", "tcpdump", "nmap", "networkQuality", "whois"].contains(name)
    }
    public static func parse(_ text: String) throws -> LocalToolCommand {
        guard text.utf8.count <= 8192, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }) else { throw ModelError.invalid("命令过长或包含控制字符。") }
        var words = [String](), word = "", quote: Character?, escaped = false, started = false
        for c in text {
            if escaped {
                if quote == "\"" && !["\\", "\"", "$", "`"].contains(c) { word.append("\\") }
                word.append(c); escaped = false; started = true; continue
            }
            if c == "\\", quote != "'" { escaped = true; started = true; continue }
            if let q = quote { if c == q { quote = nil } else { word.append(c) }; continue }
            if c == "'" || c == "\"" { quote = c; started = true; continue }
            if c == " " || c == "\t" { if started { words.append(word); word = ""; started = false }; continue }
            word.append(c); started = true
        }
        guard !escaped, quote == nil else { throw ModelError.invalid("引号或反斜杠未结束。") }
        if started { words.append(word) }
        guard let executable = words.first else { throw ModelError.invalid("请输入工具名称。") }
        let requestedName = (executable as NSString).lastPathComponent
        guard let name = names.first(where: { $0.caseInsensitiveCompare(requestedName) == .orderedSame }), !executable.contains("/") || executable.hasPrefix("/") else { throw ModelError.invalid(Self.help) }
        guard !words.dropFirst().contains(where: { ["|", "||", "&&", ";", ">", ">>", "<", "&"].contains($0) }) else { throw ModelError.invalid("请一次输入一个工具命令；此提示符不解析管道或重定向。") }
        return LocalToolCommand(name: name, arguments: Array(words.dropFirst()), explicitPath: executable.hasPrefix("/") ? executable : nil)
    }
    public func executable(environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]) throws -> String {
        let roots = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"] + (environmentPath ?? "").split(separator: ":").map(String.init)
        let candidates = explicitPath.map { [$0] } ?? roots.filter { $0.hasPrefix("/") }.map { ($0 as NSString).appendingPathComponent(name) }
        guard let found = candidates.first(where: {
            let resolved = URL(fileURLWithPath: $0).resolvingSymlinksInPath()
            return FileManager.default.isExecutableFile(atPath: resolved.path) && (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }) else {
            throw ModelError.invalid("本机未找到可执行的 \(name)。请先安装该工具，或使用已安装工具的完整路径。")
        }
        return found
    }
}
