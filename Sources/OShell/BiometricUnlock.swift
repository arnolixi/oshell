// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import LocalAuthentication
import Security
import OShellCore
#if !OSHELL_LEGACY
import CryptoKit
#endif

protocol BiometricRecordStore {
    func read(account: String) throws -> Data
    func write(_ data: Data, account: String) throws
    func remove(account: String) throws
}

private struct BiometricFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// File-based Keychain holds only an encrypted envelope, never an unprotected
/// master. The Secure Enclave enforces biometryCurrentSet during key agreement.
/// This also works with the app's ad-hoc signature, without DP-keychain entitlements.
final class BiometricKeychainStore: BiometricRecordStore {
    let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "app.oshell") + ".touch-id") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if #available(macOS 10.15, *) { query[kSecUseDataProtectionKeychain as String] = false }
        return query
    }
    func read(account: String) throws -> Data {
        var query = query(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Do not stack a login-keychain password prompt on top of Touch ID.
        // An app update that loses Keychain authorization can be re-enrolled.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw BiometricFailure(message: "无法读取本机指纹解锁记录（\(status)）。请手动输入主密码，并在设置中重新启用 Touch ID。")
        }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let query = query(account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "OShell Touch ID 主密码（仅本机）"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BiometricFailure(message: "无法保存本机钥匙串记录（\(status)）；Touch ID 未启用。") }
    }
    func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BiometricFailure(message: "Touch ID 已停用，但钥匙串记录未能删除（\(status)）。") }
    }
}

struct BiometricEnvelope: Codable {
    let version: Int
    let scope: String
    let sealedKey: Data
    let peer: Data
    let salt: Data
    let ciphertext: Data
    static func decode(_ data: Data, scope: String) throws -> BiometricEnvelope {
        guard data.count <= 16384 else { throw BiometricFailure(message: "指纹解锁记录无效，请重新启用。") }
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard record.version == 1, record.scope == scope, record.salt.count == 32, record.peer.count == 65,
              (1...8192).contains(record.sealedKey.count), (28...8192).contains(record.ciphertext.count) else {
            throw BiometricFailure(message: "指纹解锁记录与当前数据不匹配，请重新启用。")
        }
        return record
    }
}

#if !OSHELL_LEGACY
@available(macOS 10.15, *)
enum BiometricCipher {
    static func seal(_ master: String, scope: String, context: LAContext) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error) else {
            throw BiometricFailure(message: "无法建立 Touch ID 保护。")
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
        let peer = P256.KeyAgreement.PrivateKey()
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let aad = Data(("OShell.touch-id.v1:" + scope).utf8)
        let shared = try peer.sharedSecretFromKeyAgreement(with: key.publicKey)
        let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: aad, outputByteCount: 32)
        var plain = Data(master.utf8); defer { plain.resetBytes(in: 0..<plain.count) }
        let encrypted = try AES.GCM.seal(plain, using: wrapping, authenticating: aad).combined!
        return try JSONEncoder().encode(BiometricEnvelope(version: 1, scope: scope, sealedKey: key.dataRepresentation, peer: peer.publicKey.x963Representation, salt: salt, ciphertext: encrypted))
    }
    static func open(_ data: Data, scope: String, context: LAContext) throws -> String {
        let record = try BiometricEnvelope.decode(data, scope: scope)
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: record.sealedKey, authenticationContext: context)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: record.peer)
        // This operation is hardware-gated by the key's access control. A
        // successful evaluatePolicy Boolean alone never releases the master.
        let shared = try key.sharedSecretFromKeyAgreement(with: peer)
        let aad = Data(("OShell.touch-id.v1:" + scope).utf8)
        let wrapping = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: record.salt, sharedInfo: aad, outputByteCount: 32)
        var plain = try AES.GCM.open(AES.GCM.SealedBox(combined: record.ciphertext), using: wrapping, authenticating: aad)
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard let master = String(data: plain, encoding: .utf8), !master.isEmpty else { throw BiometricFailure(message: "指纹解锁记录无效。") }
        return master
    }
}
#endif

final class BiometricUnlock {
    static let shared = BiometricUnlock()
    private let store: BiometricRecordStore
    private let defaults: UserDefaults
    private(set) var scope: String?
    private let preference = "OShell.touchID.bindings.v1"
    init(store: BiometricRecordStore = BiometricKeychainStore(), defaults: UserDefaults = .standard) { self.store = store; self.defaults = defaults }
    func configure(directory: URL) {
        scope = PlatformDigest.sha256(Data(directory.standardizedFileURL.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var bindings: [String: String] { defaults.dictionary(forKey: preference) as? [String: String] ?? [:] }
    var enabled: Bool { scope.map { bindings[$0] != nil } ?? false }
    static func binding(_ configuration: Configuration) -> String? {
        guard let verifier = configuration.masterPasswordVerifier else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(verifier) else { return nil }
        return PlatformDigest.sha256(data).map { String(format: "%02x", $0) }.joined()
    }
    var unavailableReason: String? {
#if !OSHELL_LEGACY
        if #available(macOS 10.15, *) {
            guard SecureEnclave.isAvailable else { return "此 Mac 不支持 Secure Enclave，请使用主密码解锁。" }
            var error: NSError?
            guard LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return "Touch ID 当前不可用，请先在 macOS 系统设置中配置指纹，或使用主密码。" }
            return nil
        }
#endif
        return "此兼容版本不支持 Touch ID 快捷解锁，请使用主密码；支持的 Mac 可安装 macOS 11 或更新系统的 OShell 版本。"
    }
    func savePrepared(_ data: Data, binding: String, expectedScope: String) throws {
        guard scope == expectedScope else { throw BiometricFailure(message: "数据目录已变化，请重试。") }
        _ = try BiometricEnvelope.decode(data, scope: expectedScope)
        try store.write(data, account: expectedScope)
        var values = bindings; values[expectedScope] = binding; defaults.set(values, forKey: preference)
    }
    func disable() throws {
        guard let scope else { return }
        var values = bindings; values.removeValue(forKey: scope); defaults.set(values, forKey: preference)
        try store.remove(account: scope)
    }
    func invalidateIfChanged(_ configuration: Configuration) {
        guard let scope, let previous = bindings[scope], previous != Self.binding(configuration) else { return }
        try? disable()
    }
    func requestPassword() -> String? {
        guard enabled, let scope else { return nil }
        if let reason = unavailableReason { Dialogs.message(reason); return nil }
#if !OSHELL_LEGACY
        if #available(macOS 10.15, *) {
            let context = LAContext(); context.localizedReason = "使用 Touch ID 解锁 OShell 主密码"
            context.localizedFallbackTitle = ""; context.touchIDAuthenticationAllowableReuseDuration = 0
            defer { context.invalidate() }
            let store = self.store
            guard let result = CredentialTask.run(title: "Touch ID 解锁", message: "请按系统提示验证指纹。取消后可手动输入主密码。", work: { token in
                try token.check()
                let data = try store.read(account: scope)
                try token.check()
                let password = try BiometricCipher.open(data, scope: scope, context: context)
                try token.check(); return password
            }) else { return nil }
            do {
                let password = try result.get()
                guard self.scope == scope, enabled else { return nil }
                return password
            } catch {
                let failure = error as NSError
                let cancelled = (failure.domain == LAError.errorDomain && [LAError.userCancel.rawValue, LAError.systemCancel.rawValue, LAError.appCancel.rawValue, LAError.userFallback.rawValue].contains(failure.code)) || (failure.domain == NSOSStatusErrorDomain && failure.code == Int(errSecUserCanceled))
                if !cancelled { Dialogs.message((error as? BiometricFailure)?.message ?? "Touch ID 解锁未完成，请手动输入主密码。如果已更改指纹或主密码，请在设置中重新启用 Touch ID。") }
                return nil
            }
        }
#endif
        return nil
    }
}
