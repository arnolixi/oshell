// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

public enum ProxySSHAuthentication: String, Codable, CaseIterable {
    case automatic, password, privateKey
    public var title: String { switch self { case .automatic: return "自动 / SSH Agent"; case .password: return "密码"; case .privateKey: return "私钥" } }
}
public struct ProxyProfile: Codable, Equatable, Identifiable {
    public var name: String
    public var settings: ProxySettings
    public var upstreamID: UUID?
    public var id: UUID { settings.id }
    public init(name: String, settings: ProxySettings = ProxySettings(), upstreamID: UUID? = nil) {
        self.name = name; self.settings = settings; self.upstreamID = upstreamID
    }
}
public enum ProxyCatalog {
    public static let maximumHops = 8
    public static func route(_ id: UUID, in profiles: [ProxyProfile]) throws -> [ProxyProfile] {
        guard Set(profiles.map(\.id)).count == profiles.count else { throw ModelError.invalid("代理 ID 重复。") }
        let entries = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var result = [ProxyProfile](), seen = Set<UUID>(), current: UUID? = id
        while let id = current {
            guard seen.insert(id).inserted else { throw ModelError.invalid("代理链存在循环引用。") }
            guard result.count < maximumHops else { throw ModelError.invalid("代理链最多支持 8 级。") }
            guard let entry = entries[id] else { throw ModelError.invalid("代理或上级代理已不存在，请重新选择。") }
            result.append(entry); current = entry.upstreamID
        }
        return result.reversed()
    }
    public static func validate(_ profiles: [ProxyProfile], sessions: [SessionProfile]) throws {
        guard profiles.count <= 2000 else { throw ModelError.invalid("代理数量超过限制。") }
        let sessionIDs = Set(sessions.map(\.id))
        for entry in profiles {
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.name.utf8.count <= 256,
                  !entry.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), entry.settings.kind != .none,
                  !sessionIDs.contains(entry.id) else { throw ModelError.invalid("代理名称、类型或 ID 无效。") }
            try entry.settings.validate(); _ = try route(entry.id, in: profiles)
        }
        for session in sessions {
            if let id = session.proxyID {
                guard session.kind.usesSSH, session.proxy.kind == .none else { throw ModelError.invalid("共享代理仅用于 SSH / SFTP，且不能同时配置独立代理。") }
                _ = try route(id, in: profiles)
            }
        }
    }
    public static func required(for sessions: [SessionProfile], in profiles: [ProxyProfile]) throws -> [ProxyProfile] {
        var ids = Set<UUID>()
        for session in sessions { if let id = session.proxyID { for proxy in try route(id, in: profiles) { ids.insert(proxy.id) } } }
        return profiles.filter { ids.contains($0.id) }
    }
    public static func helperCommand(helper: URL, index: Int, knownHosts: URL?, tcpKeepAlive: Bool) -> String {
        var args = [helper.path, "--route-index", String(index), "--tcp-keepalive", tcpKeepAlive ? "yes" : "no"]
        if let knownHosts { args += ["--known-hosts", knownHosts.path] }
        return args.map { ConnectionValidation.quote($0.replacingOccurrences(of: "%", with: "%%")) }.joined(separator: " ") + " --target-host '%h' --target-port '%p'"
    }
}
extension Configuration {
    public mutating func migrateProxyCatalog() throws {
        for index in profiles.indices where profiles[index].proxyID == nil && profiles[index].proxy.kind != .none {
            let settings = profiles[index].proxy
            if let existing = proxies.first(where: { $0.id == settings.id }) {
                guard existing.settings == settings else { throw ModelError.invalid("旧会话的代理 ID 冲突，未迁移。") }
            } else { proxies.append(ProxyProfile(name: settings.kind.title + " · " + settings.host, settings: settings)) }
            profiles[index].proxyID = settings.id; profiles[index].proxy = ProxySettings(); profiles[index].proxy.id = settings.id
        }
        try ProxyCatalog.validate(proxies, sessions: profiles)
    }
    public func resolvingProxy(_ source: SessionProfile) throws -> SessionProfile {
        var result = source; result.runtimeProxyRoute = []
        if let id = source.proxyID { result.runtimeProxyRoute = try ProxyCatalog.route(id, in: proxies).map(\.settings) }
        else if source.proxy.kind == .jump { result.runtimeProxyRoute = [source.proxy] }
        return result
    }
}
