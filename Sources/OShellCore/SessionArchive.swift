// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Portable session definitions, never application preferences or private-key contents.
public struct SessionArchive: Codable {
    public var format = "OShell.sessions"
    public var version = 2
    public var profiles: [SessionProfile]
    public var directories: [String]
    public var passwordCount: Int { profiles.reduce(0) { $0 + ($1.encryptedPassword == nil ? 0 : 1) + ($1.proxy.encryptedPassword == nil ? 0 : 1) } }
    public static let maximumBytes = 16 * 1024 * 1024
    public init(profiles: [SessionProfile], directories: [String], includePasswords: Bool) {
        self.profiles = profiles; self.directories = directories
        if !includePasswords {
            for index in self.profiles.indices { self.profiles[index].encryptedPassword = nil; self.profiles[index].proxy.encryptedPassword = nil }
        }
    }
    public func validate() throws {
        guard format == "OShell.sessions", (1...2).contains(version), version >= 2 || !profiles.contains(where: { $0.kind.isFileSession }) else { throw ModelError.invalid("不是受支持的 OShell 会话导出文件，或文件版本过新。") }
        guard profiles.count <= 2000, directories.count <= 4000,
              Set(profiles.map(\.id)).count == profiles.count else { throw ModelError.invalid("会话文件过大或包含重复的会话 ID。") }
        for path in directories + profiles.map(\.group) {
            guard path.utf8.count <= 2048, path.split(separator: "/").count <= 32,
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  path == SessionDirectory.normalize(path) else { throw ModelError.invalid("会话目录路径无效。") }
        }
        for profile in profiles { try profile.validate() }
    }
    public func encoded() throws -> Data {
        try validate()
        guard !profiles.contains(where: { $0.encryptedPassword?.localKeyID != nil || $0.proxy.encryptedPassword?.localKeyID != nil }) else {
            throw ModelError.invalid("本机加密密码需先转换为导出密码保护，不能直接导出本机密钥引用。")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw ModelError.invalid("会话文件不能超过 16 MiB。") }; return data
    }
    public static func decode(_ data: Data) throws -> SessionArchive {
        guard data.count <= maximumBytes else { throw ModelError.invalid("会话文件不能超过 16 MiB。") }
        let archive = try JSONDecoder().decode(Self.self, from: data); try archive.validate(); return archive
    }
    public static func read(_ url: URL) throws -> SessionArchive {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ModelError.invalid("请选择普通会话文件。") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.oshellClose() }
        return try decode(handle.oshellRead(upToCount: maximumBytes + 1) ?? Data())
    }
    /// Merge as independent copies. Rebind both session and proxy credentials to new IDs.
    public func merging(into configuration: Configuration, directory: String = "", includePasswords: Bool,
                        sourceMaster: String? = nil, destinationMaster: String? = nil, destinationLocalKeyID: UUID? = nil,
                        check: () throws -> Void = {}) throws -> Configuration {
        try validate(); try check()
        var result = configuration
        if includePasswords && passwordCount > 0 {
            guard let destinationMaster, sourceMaster != nil else { throw ModelError.invalid("导入加密密码需要文件主密码和本机主密码。") }
            try ConfigurationCredentials.validateNewMaster(destinationMaster)
            if destinationLocalKeyID == nil { try ConfigurationCredentials.verify(configuration, master: destinationMaster, check: check) }
        }
        let prefix = SessionDirectory.normalize(directory)
        func path(_ value: String) -> String { [prefix, value].filter { !$0.isEmpty }.joined(separator: "/") }
        func rebind(_ source: SessionProfile, to destination: SessionProfile) throws -> EncryptedPassword? {
            try check()
            guard includePasswords, let envelope = source.encryptedPassword else { return nil }
            guard let sourceMaster, let destinationMaster else { throw ModelError.invalid("缺少导入密码。") }
            let password = try SessionCipher.decrypt(envelope, master: sourceMaster, profile: source)
            try check()
            var next = try SessionCipher.encrypt(password, master: destinationMaster, profile: destination, identity: envelope.identity)
            next.localKeyID = destinationLocalKeyID; return next
        }
        for source in profiles {
            try check()
            var next = source; next.id = UUID(); next.proxy.id = UUID(); next.group = path(source.group)
            var suffix = 1
            while result.profiles.contains(where: { $0.group == next.group && $0.name == next.name }) {
                next.name = source.name + "（导入副本\(suffix == 1 ? "" : " \(suffix)")）"; suffix += 1
            }
            next.encryptedPassword = try rebind(source, to: next)
            next.proxy.encryptedPassword = try rebind(source.proxy.credentialProfile, to: next.proxy.credentialProfile)
            result.profiles.append(next)
        }
        result.directories += directories.map(path)
        result.directories = SessionDirectory.all(result)
        try check(); return result
    }
    public func protectedForExport(password: String, credentialKey: (SessionProfile) throws -> String, check: () throws -> Void = {}) throws -> SessionArchive {
        try validate(); try ConfigurationCredentials.validateNewMaster(password)
        var result = self
        func portable(_ profile: SessionProfile) throws -> EncryptedPassword? {
            guard let envelope = profile.encryptedPassword else { return nil }
            try check()
            let secret = try SessionCipher.decrypt(envelope, master: credentialKey(profile), profile: profile)
            try check()
            return try SessionCipher.encrypt(secret, master: password, profile: profile, identity: envelope.identity)
        }
        for index in result.profiles.indices {
            result.profiles[index].encryptedPassword = try portable(profiles[index])
            result.profiles[index].proxy.encryptedPassword = try portable(profiles[index].proxy.credentialProfile)
        }
        try check(); return result
    }
}
