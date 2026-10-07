// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Initial values for new saved sessions. Existing profiles own their settings.
public struct SessionDefaults: Codable, Equatable {
    public var sshPort = 22
    public var sshUsername = ""
    public var identityFile = ""
    public var legacySSH = false
    public var sshDirectory = "."
    public var ftpPort = 21
    public var ftpUsername = "anonymous"
    public var ftpDirectory = "/"
    public var quickConnect = true
    public var keepAlive = KeepAliveSettings()
    public init() {}
    public func makeProfile(kind: SessionKind, directory: String) -> SessionProfile {
        var profile = SessionProfile(name: "新 " + kind.title + " 会话", group: directory, kind: kind)
        profile.quickConnect = quickConnect
        if kind.usesSSH {
            profile.port = sshPort; profile.username = sshUsername; profile.identityFile = identityFile
            profile.legacySSH = legacySSH; profile.initialDirectory = sshDirectory; profile.keepAlive = keepAlive
            if kind == .sftp { profile.keepAlive.idleEnabled = false }
        } else if kind == .ftp {
            profile.port = ftpPort; profile.username = ftpUsername; profile.initialDirectory = ftpDirectory
        }
        return profile
    }
    public func validate() throws {
        try keepAlive.validate()
        for kind in [SessionKind.ssh, .ftp] {
            var profile = makeProfile(kind: kind, directory: "")
            profile.host = "defaults.example"; try profile.validate()
        }
    }
}

public enum SessionDuplication {
    public static func name(for source: SessionProfile, among profiles: [SessionProfile]) -> String {
        let names = Set(profiles.filter { $0.group == source.group }.map(\.name))
        let base = source.name + " - 副本"
        var name = base, suffix = 2
        while names.contains(name) { name = base + " \(suffix)"; suffix += 1 }
        return name
    }
    public static func copy(_ source: SessionProfile, among profiles: [SessionProfile], master: String? = nil, credentialKey: ((SessionProfile) throws -> String)? = nil,
                            checkCancellation: () throws -> Void = {}) throws -> SessionProfile {
        try checkCancellation()
        var copy = source; copy.id = UUID(); copy.proxy.id = UUID()
        copy.name = name(for: source, among: profiles)
        for index in copy.tunnels.indices { copy.tunnels[index].id = UUID() }
        func rebind(_ old: SessionProfile, _ new: SessionProfile) throws -> EncryptedPassword? {
            guard let envelope = old.encryptedPassword else { return nil }
            guard let master = try credentialKey?(old) ?? master else { throw ModelError.invalid("复制已保存的密码需要先解锁主密码。"); }
            try checkCancellation()
            let password = try SessionCipher.decrypt(envelope, master: master, profile: old)
            try checkCancellation()
            var result = try SessionCipher.encrypt(password, master: master, profile: new, identity: envelope.identity)
            result.localKeyID = envelope.localKeyID; return result
        }
        copy.encryptedPassword = try rebind(source, copy)
        copy.proxy.encryptedPassword = try rebind(source.proxy.credentialProfile, copy.proxy.credentialProfile)
        try checkCancellation(); try copy.validate(); return copy
    }
}
