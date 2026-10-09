// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public struct SharedConfigurationConflict: Error, LocalizedError {
    public let base: Configuration
    public let remote: Configuration
    public let fingerprint: Data
    public var errorDescription: String? { "共享配置已改变，请处理差异后保存。" }
}
public struct SharedConfigurationSnapshot {
    public let configuration: Configuration
    public let fingerprint: Data
}

/// Whole-session three-way merging: edits on both sides always require an
/// explicit decision, even if the changed fields differ. IDs, never names, match sessions.
public final class ConfigurationMerge {
    public enum Choice: Equatable { case local, remote }
    public struct Conflict {
        public let key: String
        public let title: String
        public let localDescription: String
        public let remoteDescription: String
    }
    public private(set) var conflicts = [Conflict]()
    private var merged: [String: Any]
    private var profiles = [UUID: SessionProfile]()
    private var profileOrder = [UUID]()
    private let local: Configuration, remote: Configuration
    private let localFields: [String: Any], remoteFields: [String: Any]

    private static func fields<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        let left = try? JSONSerialization.data(withJSONObject: [a ?? NSNull()], options: [.sortedKeys])
        let right = try? JSONSerialization.data(withJSONObject: [b ?? NSNull()], options: [.sortedKeys])
        return left == right
    }
    private static func redact(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { $0 }.reduce(into: [String: Any]()) { result, pair in
                let key = pair.key.lowercased()
                result[pair.key] = ["password", "ciphertext", "salt", "secret", "token"].contains(where: key.contains) ? "已设置（内容不展示）" : redact(pair.value)
            }
        }
        if let array = value as? [Any] { return array.map(redact) }
        return value
    }
    private static func describe(_ value: Any?) -> String {
        guard let value else { return "已删除 / 未设置" }
        guard let data = try? JSONSerialization.data(withJSONObject: redact(value), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return "值已改变" }
        return String(decoding: data, as: UTF8.self)
    }
    private static func describe(_ profile: SessionProfile?, base: SessionProfile?) -> String {
        guard let profile else { return "此版本已删除该会话。" }
        let changedPassword = profile.encryptedPassword != base?.encryptedPassword || profile.proxy.encryptedPassword != base?.proxy.encryptedPassword
        return "名称：\(profile.name)\n目录：\(SessionDirectory.display(profile.group))\n协议：\(profile.kind.title)\n主机：\(profile.host)\n端口：\(profile.port)\n用户名：\(profile.username)\n密码：\(changedPassword ? "与共同基准不同（不展示内容）" : "未改变")\n\n完整配置（密码已隐藏）：\n" + describe(try? fields(profile))
    }
    public init(base: Configuration, local: Configuration, remote: Configuration) throws {
        guard base.masterPasswordVerifier == local.masterPasswordVerifier,
              base.masterPasswordVerifier == remote.masterPasswordVerifier,
              base.hasMasterPassword == local.hasMasterPassword, base.hasMasterPassword == remote.hasMasterPassword else {
            throw ModelError.invalid("主密码保护已改变，不能合并密码保护状态。请重新载入或重启解锁后再编辑。")
        }
        guard [base, local, remote].allSatisfy({ Set($0.profiles.map(\.id)).count == $0.profiles.count }) else { throw ModelError.invalid("配置含有重复会话 ID，无法安全合并。") }
        self.local = local; self.remote = remote
        let baseFields = try Self.fields(base)
        localFields = try Self.fields(local); remoteFields = try Self.fields(remote)
        merged = remoteFields
        let labels = ["preferences":"应用设置", "directories":"会话目录", "quickCommands":"快速命令", "highlightSets":"突出显示集", "sessionLinks":"快捷引用", "sessionDefaults":"默认会话属性"]
        for key in Set(baseFields.keys).union(localFields.keys).union(remoteFields.keys).sorted() where key != "profiles" {
            let b = baseFields[key], l = localFields[key], r = remoteFields[key]
            if Self.equal(l, r) || Self.equal(r, b) { merged[key] = l }
            else if !Self.equal(l, b) {
                conflicts.append(.init(key: key, title: labels[key] ?? key, localDescription: Self.describe(l), remoteDescription: Self.describe(r)))
            }
        }
        let baseByID = Dictionary(uniqueKeysWithValues: base.profiles.map { ($0.id, $0) })
        let localByID = Dictionary(uniqueKeysWithValues: local.profiles.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.profiles.map { ($0.id, $0) })
        var seen = Set<UUID>()
        profileOrder = (remote.profiles + local.profiles + base.profiles).map(\.id).filter { seen.insert($0).inserted }
        for id in profileOrder {
            let b = baseByID[id], l = localByID[id], r = remoteByID[id]
            if l == r || r == b { profiles[id] = l }
            else if l == b { profiles[id] = r }
            else {
                conflicts.append(.init(key: "profile:" + id.uuidString, title: (l ?? r ?? b)!.name,
                                       localDescription: Self.describe(l, base: b), remoteDescription: Self.describe(r, base: b)))
            }
        }
    }
    public func resolve(_ choices: [String: Choice]) throws -> Configuration {
        var result = merged, selected = profiles
        for conflict in conflicts {
            guard let choice = choices[conflict.key] else { throw ModelError.invalid("请为每个冲突项目选择要保留的版本。") }
            let source = choice == .local ? local : remote
            if conflict.key.hasPrefix("profile:"), let id = UUID(uuidString: String(conflict.key.dropFirst(8))) {
                selected[id] = source.profiles.first { $0.id == id }
            } else { result[conflict.key] = (choice == .local ? localFields : remoteFields)[conflict.key] }
        }
        result["profiles"] = try profileOrder.compactMap { selected[$0] }.map(Self.fields)
        var configuration = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: result))
        try configuration.migrateFileSessions()
        configuration.sessionLinks.normalize(profiles: configuration.profiles)
        configuration.normalizeSessionLinkDirectories()
        return configuration
    }
}
