// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public enum TunnelKind: String, Codable, CaseIterable {
    case local, remote, dynamic
    public var title: String { switch self { case .local: return "本地转发"; case .remote: return "远程转发"; case .dynamic: return "动态 SOCKS4/5" } }
}
public struct TunnelRule: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var enabled = true
    public var kind: TunnelKind = .local
    public var bindHost = "127.0.0.1"
    public var listenPort = 8080
    public var destinationHost = "localhost"
    public var destinationPort = 80
    public var note = ""
    public init() {}
    public func validate() throws {
        guard (1...65535).contains(listenPort), ConnectionValidation.host(bindHost) else { throw ModelError.invalid("隧道监听地址或端口无效。") }
        if kind != .dynamic {
            guard ConnectionValidation.host(destinationHost), (1...65535).contains(destinationPort) else { throw ModelError.invalid("隧道目标地址或端口无效。") }
        }
    }
    public var arguments: [String] {
        let source = "\(ConnectionValidation.bracket(bindHost)):\(listenPort)"
        switch kind {
        case .dynamic: return ["-D", source]
        case .local, .remote:
            return [kind == .local ? "-L" : "-R", "\(source):\(ConnectionValidation.bracket(destinationHost)):\(destinationPort)"]
        }
    }
}
public enum ProxyKind: String, Codable, CaseIterable {
    case none, socks4, socks4a, socks5, http, jump
    public var title: String {
        switch self { case .none: return "无代理"; case .socks4: return "SOCKS4"; case .socks4a: return "SOCKS4A"; case .socks5: return "SOCKS5"; case .http: return "HTTP CONNECT"; case .jump: return "SSH 跳板机" }
    }
}
public struct ProxySettings: Codable, Equatable {
    public var id = UUID()
    public var kind: ProxyKind = .none
    public var host = ""
    public var port = 1080
    public var username = ""
    public var encryptedPassword: EncryptedPassword?
    public init() {}
    public var needsHelper: Bool { kind != .none && kind != .jump }
    public var supportsPassword: Bool { kind == .socks5 || kind == .http }
    public func validate() throws {
        guard kind != .none else { return }
        guard ConnectionValidation.host(host), (1...65535).contains(port) else { throw ModelError.invalid("代理主机或端口无效。") }
        guard !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), username.utf8.count <= 255,
              kind != .http || !username.contains(":") else { throw ModelError.invalid("代理用户名无效或过长。") }
        if kind == .jump, !username.isEmpty, !ConnectionValidation.user(username) { throw ModelError.invalid("跳板机用户名无效。") }
    }
    public var credentialProfile: SessionProfile {
        var value = SessionProfile(id: id, name: "代理 \(host)", host: host, port: port, username: username)
        value.encryptedPassword = encryptedPassword
        return value
    }
    public func command(helper: URL, tcpKeepAlive: Bool = true) -> String {
        let parts = [helper.path, "--type", kind.rawValue, "--host", host, "--port", String(port), "--user", username, "--tcp-keepalive", tcpKeepAlive ? "yes" : "no"]
        // OpenSSH expands percent tokens before handing ProxyCommand to the shell.
        return parts.map { ConnectionValidation.quote($0.replacingOccurrences(of: "%", with: "%%")) }.joined(separator: " ") + " --target-host '%h' --target-port '%p'"
    }
}
public struct KeepAliveSettings: Codable, Equatable {
    public var enabled = true
    public var interval = 30
    public var maxMissed = 3
    public var tcp = true
    public var idleEnabled = false
    public var idleInterval = 3600
    public var idleText = "\\n"
    public init() {}
    /// Merge only application-owned idle settings, preserving SSH process options.
    public func replacingIdle(with value: KeepAliveSettings) throws -> KeepAliveSettings {
        var updated = self
        updated.idleEnabled = value.idleEnabled; updated.idleInterval = value.idleInterval; updated.idleText = value.idleText
        try updated.validate(); return updated
    }
    public func validate() throws {
        guard (1...86400).contains(interval), (1...100).contains(maxMissed), (1...86400).contains(idleInterval) else { throw ModelError.invalid("保活间隔应为 1–86400 秒，最大未响应次数为 1–100。") }
        if idleEnabled { _ = try idleBytes() }
    }
    public func idleBytes() throws -> [UInt8] {
        var output = "", escaped = false
        for char in idleText {
            if escaped {
                switch char { case "n": output += "\n"; case "r": output += "\r"; case "t": output += "\t"; case "e": output += "\u{1b}"; case "\\": output += "\\"; default: throw ModelError.invalid("空闲字符串仅支持 \\n、\\r、\\t、\\e 和 \\\\ 转义。") }
                escaped = false
            } else if char == "\\" { escaped = true } else { output.append(char) }
        }
        guard !escaped, !output.isEmpty, output.utf8.count <= 1024, !output.contains("\0") else { throw ModelError.invalid("空闲字符串为空、过长或转义不完整。") }
        return Array(output.utf8)
    }
}
public enum ConnectionValidation {
    public static func host(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]").contains($0)
        }
    }
    public static func user(_ value: String) -> Bool {
        !value.hasPrefix("-") && !value.isEmpty && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || "@%".unicodeScalars.contains($0) }
    }
    public static func bracket(_ host: String) -> String { host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public enum SessionDirectory {
    /// POSIX-style presentation; storage keeps the existing root-relative keys.
    public static func display(_ path: String) -> String { "/" + normalize(path) }
    public static func resolvePath(_ input: String, relativeTo base: String = "") throws -> String {
        guard input.utf8.count <= 4096, !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ModelError.invalid("目录路径不能包含控制字符，且不得超过 4 KB。")
        }
        guard !input.contains("\\") else { throw ModelError.invalid("请使用 Linux 目录格式，以 / 分隔目录，例如 /生产/机房。") }
        let value = input.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "" }
        var parts = value.hasPrefix("/") ? [String]() : normalize(base).split(separator: "/").map(String.init)
        for raw in value.split(separator: "/") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            if part.isEmpty || part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    public static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0 != "." && $0 != ".." }.joined(separator: "/")
    }
    public static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
    public static func all(_ configuration: Configuration) -> [String] {
        var result = Set<String>()
        for path in configuration.directories + configuration.profiles.map(\.group) + [SessionLinks.rootDirectory] + configuration.sessionLinks.allFolders.map({ SessionLinks.directory(for: $0) }) {
            var parts = [String]()
            for part in normalize(path).split(separator: "/") { parts.append(String(part)); result.insert(parts.joined(separator: "/")) }
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public static func contains(_ path: String, in directory: String) -> Bool { path == directory || path.hasPrefix(directory + "/") }
}
