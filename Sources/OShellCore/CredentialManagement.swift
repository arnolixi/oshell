// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public struct CredentialRotation {
    public let configuration: Configuration
    /// Old ciphertext -> new envelope, for still-open connection snapshots.
    public let replacements: [String: EncryptedPassword]
}

public enum ConfigurationCredentials {
    public static func profiles(in configuration: Configuration) -> [SessionProfile] {
        configuration.profiles + configuration.profiles.map { $0.proxy.credentialProfile } + configuration.ftpProfiles.map(\.credentialProfile) + configuration.proxies.map { $0.settings.credentialProfile }
    }
    /// Counts only user-master-protected credentials; local encryption is independent.
    public static func count(in configuration: Configuration) -> Int { profiles(in: configuration).filter { $0.encryptedPassword != nil && $0.encryptedPassword?.localKeyID == nil }.count }
    public static func validateNewMaster(_ master: String) throws {
        guard master.count >= 8, master.utf8.count <= 1024 else { throw ModelError.invalid("新主密码应为至少 8 个字符，且不超过 1024 字节。") }
    }
    public static func verify(_ configuration: Configuration, master: String, check: () throws -> Void = {}) throws {
        if let verifier = configuration.masterPasswordVerifier { try MasterPasswordProtection.verify(verifier, password: master) }
        for profile in profiles(in: configuration) {
            try check()
            if let envelope = profile.encryptedPassword, envelope.localKeyID == nil { _ = try SessionCipher.decrypt(envelope, master: master, profile: profile) }
        }
    }
    public static func rotate(_ configuration: Configuration, oldMaster: String, newMaster: String,
                              check: () throws -> Void = {}) throws -> CredentialRotation {
        try validateNewMaster(newMaster)
        guard oldMaster != newMaster else { throw ModelError.invalid("新主密码不能与原主密码相同。") }
        guard configuration.hasMasterPassword else { throw ModelError.invalid("尚未设置主密码。") }
        if let verifier = configuration.masterPasswordVerifier { try MasterPasswordProtection.verify(verifier, password: oldMaster) }
        var result = configuration, replacements = [String: EncryptedPassword]()
        func change(_ profile: SessionProfile) throws -> EncryptedPassword? {
            try check()
            guard let old = profile.encryptedPassword else { return nil }
            if old.localKeyID != nil { return old }
            let password = try SessionCipher.decrypt(old, master: oldMaster, profile: profile)
            try check()
            let next = try SessionCipher.encrypt(password, master: newMaster, profile: profile, identity: old.identity)
            replacements[old.ciphertext] = next; return next
        }
        for index in result.profiles.indices {
            result.profiles[index].encryptedPassword = try change(configuration.profiles[index])
            result.profiles[index].proxy.encryptedPassword = try change(configuration.profiles[index].proxy.credentialProfile)
        }
        for index in result.ftpProfiles.indices { result.ftpProfiles[index].encryptedPassword = try change(configuration.ftpProfiles[index].credentialProfile) }
        for index in result.proxies.indices { result.proxies[index].settings.encryptedPassword = try change(configuration.proxies[index].settings.credentialProfile) }
        result.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(newMaster)
        try check()
        return CredentialRotation(configuration: result, replacements: replacements)
    }
}
