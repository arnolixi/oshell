// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import CommonCrypto

/// Import-only compatibility for master-password protected RC4/SHA-256 records.
/// Never serialize vendor ciphertext into OShell configuration or diagnostics.
public struct XshellSavedPassword: CustomStringConvertible, CustomDebugStringConvertible {
    private let encoded: String
    public init(encoded: String) { self.encoded = encoded }
    public var description: String { "<Xshell encrypted password>" }
    public var debugDescription: String { description }
    public func decrypt(master: String) throws -> String {
        guard !master.isEmpty, master.utf8.count <= 4096, encoded.utf8.count <= 8192,
              let packet = Data(base64Encoded: encoded), packet.count > 32, packet.count <= 4128 else {
            throw ModelError.invalid("Xshell 密码记录无效或格式不受支持；请使用包含密码的原始导出文件。")
        }
        func hash(_ bytes: [UInt8]) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = bytes.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(bytes.count), &result) }; return result
        }
        var key = hash(Array(master.utf8)), plain = [UInt8](repeating: 0, count: packet.count - 32)
        defer {
            key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            plain.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        let cipher = Array(packet.dropLast(32)), expected = Array(packet.suffix(32))
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in cipher.withUnsafeBytes { input in
            plain.withUnsafeMutableBytes { output in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmRC4), 0, keyBytes.baseAddress, key.count,
                        nil, input.baseAddress, cipher.count, output.baseAddress, output.count, &written)
            }
        } }
        let actual = hash(plain)
        let difference = zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard status == kCCSuccess, written == cipher.count, difference == 0 else {
            throw ModelError.invalid("Xshell 主密码不正确、文件损坏，或密码使用了尚不支持的加密格式。未保存任何导入结果。")
        }
        guard let password = String(bytes: plain, encoding: .utf8), !password.isEmpty,
              !password.contains("\0"), !password.contains("\r"), !password.contains("\n") else { throw ModelError.invalid("密码编码或控制字符不受支持，未保存导入结果。") }
        return password
    }
}

public struct ThirdPartyPasswordImportResult {
    public let configuration: Configuration
    public let importedSessions: Int
    public let importedPasswords: Int
    public let preservedPasswords: Int
    public let unmatchedSessions: Int
}

extension ThirdPartySessionReport {
    /// All-or-nothing: no mutation of input config, no connection or plaintext file.
    public func importingPasswords(into configuration: Configuration, directory: String,
                                   sourceMaster: String, destinationSecret: String, destinationLocalKeyID: UUID?,
                                   fillMissingOnly: Bool, check: () throws -> Void = {}) throws -> ThirdPartyPasswordImportResult {
        try archive.validate(); try check()
        if destinationLocalKeyID == nil { try MasterPasswordProtection.verifyStartup(configuration, password: destinationSecret) }
        else if configuration.hasMasterPassword { throw ModelError.invalid("已有 OShell 主密码，不能将导入密码改为无主密码存储。") }
        var result = fillMissingOnly ? configuration : try archive.merging(into: configuration, directory: directory, includePasswords: false, check: check)
        var updated = 0, preserved = 0, unmatched = 0
        let scope = SessionDirectory.normalize(directory)
        var used = Set<UUID>()
        for (offset, original) in profiles.enumerated() {
            try check()
            guard let encrypted = xshellPasswords[original.id] else { continue }
            let index: Int
            if fillMissingOnly {
                let matching = result.profiles.indices.filter {
                    let target = result.profiles[$0]
                    return target.name == original.name && target.kind == original.kind && target.host == original.host && target.port == original.port && target.username == original.username
                }
                let samePath = matching.filter { result.profiles[$0].group == original.group || result.profiles[$0].group.hasSuffix("/" + original.group) }
                let candidates = (samePath.isEmpty ? matching : samePath).filter { scope.isEmpty || SessionDirectory.contains(result.profiles[$0].group, in: scope) }
                guard candidates.count <= 1 else { throw ModelError.invalid("找到多个同名且连接信息相同的会话。请在会话管理中进入更具体的目录后重新导入，未修改任何会话。") }
                guard let found = candidates.first else { unmatched += 1; continue }; index = found
                guard used.insert(result.profiles[index].id).inserted else { throw ModelError.invalid("导出文件包含重复的匹配会话，无法确定密码归属。") }
                if result.profiles[index].encryptedPassword != nil { preserved += 1; continue }
            } else { index = configuration.profiles.count + offset }
            let target = result.profiles[index]
            let password = try encrypted.decrypt(master: sourceMaster)
            try check()
            var envelope = try SessionCipher.encrypt(password, master: destinationSecret, profile: target,
                                                      identity: SSHIdentity(host: target.host, user: target.username, port: target.port))
            envelope.localKeyID = destinationLocalKeyID
            result.profiles[index].encryptedPassword = envelope; updated += 1
        }
        try check()
        return ThirdPartyPasswordImportResult(configuration: result, importedSessions: fillMissingOnly ? 0 : profiles.count,
                                              importedPasswords: updated, preservedPasswords: preserved, unmatchedSessions: unmatched)
    }
}
