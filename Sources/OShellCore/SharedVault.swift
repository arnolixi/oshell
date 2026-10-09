// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import CommonCrypto
import Security
#if OSHELL_LEGACY
import CryptoSwift
#else
import CryptoKit
#endif

public enum SharingProtection {
    public static func require(_ configuration: Configuration) throws {
        guard configuration.masterPasswordVerifier != nil else { throw ModelError.invalid("共享或自定义数据目录必须先设置主密码。") }
        guard !ConfigurationCredentials.profiles(in: configuration).contains(where: { $0.encryptedPassword?.localKeyID != nil }) else {
            throw ModelError.invalid("仍有密码使用本机密钥保护。请先将所有保存密码转换为主密码加密。")
        }
    }
}
public enum SharedVault {
    private struct Envelope: Codable {
        let format: String
        let version: Int
        let iterations: Int
        let salt: Data
        let ciphertext: Data
    }
    public static let maximumSize = 48 * 1024 * 1024
    private static let aad = Data("OShell.shared-vault.v1".utf8)
    public static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"] as? String == "OShell.shared-vault"
    }
    private static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw ModelError.invalid("无法生成加密随机数。") }
        return Data(bytes)
    }
    private static func key(_ password: String, salt: Data, rounds: Int) throws -> [UInt8] {
        guard !password.isEmpty, password.utf8.count <= 4096, salt.count == 16, (600_000...2_000_000).contains(rounds) else { throw ModelError.invalid("共享数据加密参数无效。") }
        var result = [UInt8](repeating: 0, count: 32)
        let utf8 = Data(password.utf8)
        let status = utf8.withUnsafeBytes { input in salt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress!.assumingMemoryBound(to: CChar.self), utf8.count, salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &result, 32)
        } }
        guard status == kCCSuccess else { throw ModelError.invalid("无法派生共享数据密钥。") }
        return result
    }
    public static func seal(_ data: Data, password: String) throws -> Data {
        guard data.count <= 32 * 1024 * 1024 else { throw ModelError.invalid("共享数据超过大小限制。") }
        let salt = try random(16), rounds = 600_000
        var derived = try key(password, salt: salt, rounds: rounds)
        defer { derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let combined: Data
        #if OSHELL_LEGACY
        let nonce = try random(12)
        let mode = GCM(iv: Array(nonce), additionalAuthenticatedData: Array(aad), tagLength: 16, mode: .combined)
        combined = nonce + Data(try AES(key: derived, blockMode: mode, padding: .noPadding).encrypt(Array(data)))
        #else
        combined = try AES.GCM.seal(data, using: SymmetricKey(data: derived), authenticating: aad).combined!
        #endif
        return try JSONEncoder().encode(Envelope(format: "OShell.shared-vault", version: 1, iterations: rounds, salt: salt, ciphertext: combined))
    }
    public static func open(_ data: Data, password: String) throws -> Data {
        guard data.count <= maximumSize else { throw ModelError.invalid("共享数据超过大小限制。") }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.format == "OShell.shared-vault", envelope.version == 1, envelope.ciphertext.count >= 28 else { throw ModelError.invalid("共享数据格式无效。") }
            var derived = try key(password, salt: envelope.salt, rounds: envelope.iterations)
            defer { derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            #if OSHELL_LEGACY
            let mode = GCM(iv: Array(envelope.ciphertext.prefix(12)), additionalAuthenticatedData: Array(aad), tagLength: 16, mode: .combined)
            return Data(try AES(key: derived, blockMode: mode, padding: .noPadding).decrypt(Array(envelope.ciphertext.dropFirst(12))))
            #else
            return try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: SymmetricKey(data: derived), authenticating: aad)
            #endif
        } catch { throw ModelError.invalid("主密码不正确，或共享数据已损坏。") }
    }
    public static func encode(_ configuration: Configuration, password: String) throws -> Data {
        try SharingProtection.require(configuration)
        try MasterPasswordProtection.verifyStartup(configuration, password: password)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try seal(encoder.encode(configuration), password: password)
    }
    public static func decode(_ data: Data, password: String) throws -> Configuration {
        var value = try JSONDecoder().decode(Configuration.self, from: open(data, password: password))
        try value.migrateFileSessions(); try SharingProtection.require(value)
        try MasterPasswordProtection.verifyStartup(value, password: password)
        for profile in value.profiles { try profile.validate() }
        return value
    }
}
