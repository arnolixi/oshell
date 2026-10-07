// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// A persistent password verifier independent of whether any session is saved.
public enum MasterPasswordProtection {
    private static let marker = "OShell master password verifier v1"
    private static let profile = SessionProfile(id: UUID(uuidString: "F7FCF275-EB85-488F-AF21-A0424101259A")!, name: "OShell 主密码校验", host: "oshell-vault", username: "vault")
    public static func createVerifier(_ password: String) throws -> EncryptedPassword {
        try ConfigurationCredentials.validateNewMaster(password)
        return try SessionCipher.encrypt(marker, master: password, profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
    }
    public static func verify(_ verifier: EncryptedPassword, password: String) throws {
        guard verifier.localKeyID == nil,
              try SessionCipher.decrypt(verifier, master: password, profile: profile) == marker else { throw ModelError.invalid("主密码校验失败。"); }
    }
    public static func verifyStartup(_ configuration: Configuration, password: String) throws {
        if let verifier = configuration.masterPasswordVerifier { try verify(verifier, password: password) }
        else {
            guard ConfigurationCredentials.count(in: configuration) > 0 else { throw ModelError.invalid("尚未设置主密码。"); }
            try ConfigurationCredentials.verify(configuration, master: password)
        }
    }
    public static func enabling(_ configuration: Configuration, password: String,
                                credentialKey: (SessionProfile) throws -> String,
                                check: () throws -> Void = {}) throws -> CredentialRotation {
        try ConfigurationCredentials.validateNewMaster(password); try check()
        if configuration.hasMasterPassword { try verifyStartup(configuration, password: password) }
        var result = configuration, replacements = [String: EncryptedPassword]()
        func migrate(_ profile: SessionProfile) throws -> EncryptedPassword? {
            guard let old = profile.encryptedPassword, old.localKeyID != nil else { return profile.encryptedPassword }
            try check()
            let plain = try SessionCipher.decrypt(old, master: credentialKey(profile), profile: profile)
            try check()
            let next = try SessionCipher.encrypt(plain, master: password, profile: profile, identity: old.identity)
            replacements[old.ciphertext] = next; return next
        }
        for index in result.profiles.indices {
            result.profiles[index].encryptedPassword = try migrate(configuration.profiles[index])
            result.profiles[index].proxy.encryptedPassword = try migrate(configuration.profiles[index].proxy.credentialProfile)
        }
        for index in result.ftpProfiles.indices { result.ftpProfiles[index].encryptedPassword = try migrate(configuration.ftpProfiles[index].credentialProfile) }
        if result.masterPasswordVerifier == nil { result.masterPasswordVerifier = try createVerifier(password) }
        try check(); return CredentialRotation(configuration: result, replacements: replacements)
    }
    /// Remove startup protection only after verifying and converting all saved credentials.
    /// The key provider runs after authentication, and is unnecessary for an empty vault.
    public static func disabling(_ configuration: Configuration, password: String,
                                 localKey: () throws -> LocalCredentialKey,
                                 check: () throws -> Void = {}) throws -> CredentialRotation {
        try check(); try verifyStartup(configuration, password: password); try check()
        let key = ConfigurationCredentials.count(in: configuration) > 0 ? try localKey() : nil
        if let key, Data(base64Encoded: key.secret)?.count != 32 { throw ModelError.invalid("本机加密密钥格式不正确。") }
        var result = configuration, replacements = [String: EncryptedPassword]()
        func convert(_ profile: SessionProfile) throws -> EncryptedPassword? {
            try check()
            guard let old = profile.encryptedPassword, old.localKeyID == nil else { return profile.encryptedPassword }
            guard let key else { throw ModelError.invalid("缺少本机加密密钥。") }
            let plain = try SessionCipher.decrypt(old, master: password, profile: profile)
            try check()
            var next = try SessionCipher.encrypt(plain, master: key.secret, profile: profile, identity: old.identity)
            next.localKeyID = key.id; replacements[old.ciphertext] = next; return next
        }
        for index in result.profiles.indices {
            result.profiles[index].encryptedPassword = try convert(configuration.profiles[index])
            result.profiles[index].proxy.encryptedPassword = try convert(configuration.profiles[index].proxy.credentialProfile)
        }
        for index in result.ftpProfiles.indices { result.ftpProfiles[index].encryptedPassword = try convert(configuration.ftpProfiles[index].credentialProfile) }
        result.masterPasswordVerifier = nil
        try check(); return CredentialRotation(configuration: result, replacements: replacements)
    }

}
