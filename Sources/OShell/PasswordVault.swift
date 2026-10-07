// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class PasswordVault {
    static let shared = PasswordVault()
    private var master: String?
    var cachedMaster: String? { master }
    private(set) var masterProtectionEnabled = false
    private var verifier: EncryptedPassword?
    func configureProtection(_ configuration: Configuration) {
        masterProtectionEnabled = configuration.hasMasterPassword; verifier = configuration.masterPasswordVerifier
    }
    func migrationKey(_ profile: SessionProfile, master: String) throws -> String {
        if let id = profile.encryptedPassword?.localKeyID {
            guard let localStore else { throw ModelError.invalid("本机密码存储尚未初始化。") }
            return try localStore.load(expectedID: id).secret
        }
        return master
    }
    private var generation = 0
    private var replacements = [String: EncryptedPassword]()
    private var localStore: LocalCredentialStore?
    func configureLocalStorage(directory: URL) { localStore = LocalCredentialStore(directory: directory) }
    func localKeyForSaving(knownProfiles: [SessionProfile]) throws -> LocalCredentialKey {
        guard let localStore else { throw ModelError.invalid("OShell 本机密码存储尚未初始化。"); }
        return try localStore.keyForSaving(knownProfiles: knownProfiles)
    }
    private func key(for envelope: EncryptedPassword) throws -> String? {
        if let id = envelope.localKeyID {
            guard let localStore else { throw ModelError.invalid("OShell 本机密码存储尚未初始化。"); }
            return try localStore.load(expectedID: id).secret
        }
        return requestMaster(creating: false)
    }
    func credentialKeys(for profiles: [SessionProfile]) throws -> [String: String]? {
        var result = [String: String]()
        var requestedMaster = master
        for profile in profiles.map(currentCredential) {
            guard let envelope = profile.encryptedPassword else { continue }
            if envelope.localKeyID == nil {
                if requestedMaster == nil { requestedMaster = requestMaster(creating: false) }
                guard let value = requestedMaster else { return nil }; result[envelope.ciphertext] = value
            } else { guard let value = try key(for: envelope) else { return nil }; result[envelope.ciphertext] = value }
        }
        return result
    }
    func readSavedPassword(_ original: SessionProfile) throws -> String? {
        let profile = currentCredential(original)
        guard let envelope = profile.encryptedPassword, let candidate = try key(for: envelope) else { return nil }
        do {
            let password = try SessionCipher.decrypt(envelope, master: candidate, profile: profile)
            if envelope.localKeyID == nil { master = candidate }; return password
        } catch { if envelope.localKeyID == nil { lock() }; throw error }
    }
    func protect(_ password: String, profile: SessionProfile, knownProfiles: [SessionProfile], protection: PasswordProtection, identity: SSHIdentity? = nil) throws -> EncryptedPassword? {
        if protection == .master { return try encrypt(password, profile: profile, knownProfiles: knownProfiles, identity: identity) }
        guard !masterProtectionEnabled else { throw ModelError.invalid("已设置主密码，请使用主密码保护保存的密码。") }
        let key = try localKeyForSaving(knownProfiles: knownProfiles)
        let identity = try identity ?? SSHIdentity.resolve(profile)
        var envelope = try SessionCipher.encrypt(password, master: key.secret, profile: profile, identity: identity)
        envelope.localKeyID = key.id; return envelope
    }
    func lock() { generation += 1; master = nil }
    func unlockForTesting(_ value: String) { generation += 1; master = value }
    func acceptMaster(_ value: String) { generation += 1; master = value }
    func acceptRotation(_ rotation: CredentialRotation, master value: String) {
        applyReplacements(rotation); acceptMaster(value)
    }
    func acceptMasterRemoval(_ rotation: CredentialRotation) {
        applyReplacements(rotation); lock()
    }
    private func applyReplacements(_ rotation: CredentialRotation) {
        for (key, envelope) in replacements {
            if let next = rotation.replacements[envelope.ciphertext] { replacements[key] = next }
        }
        replacements.merge(rotation.replacements) { _, next in next }
    }
    func currentCredential(_ original: SessionProfile) -> SessionProfile {
        var profile = original
        if let old = profile.encryptedPassword, let next = replacements[old.ciphertext] { profile.encryptedPassword = next }
        return profile
    }
    func currentCredentials(in original: Configuration) -> Configuration {
        var configuration = original
        for index in configuration.profiles.indices {
            configuration.profiles[index].encryptedPassword = currentCredential(original.profiles[index]).encryptedPassword
            configuration.profiles[index].proxy.encryptedPassword = currentCredential(original.profiles[index].proxy.credentialProfile).encryptedPassword
        }
        for index in configuration.ftpProfiles.indices {
            configuration.ftpProfiles[index].encryptedPassword = currentCredential(original.ftpProfiles[index].credentialProfile).encryptedPassword
        }
        return configuration
    }
    func masterForImport(hasSavedPasswords: Bool) -> String? { requestMaster(creating: !hasSavedPasswords && !masterProtectionEnabled) }
    static func promptMaster(title: String, creating: Bool) -> String? {
        let vault = PasswordVault()
        return vault.requestMaster(creating: creating, title: title)
    }
    private func requestMaster(creating: Bool, title: String? = nil) -> String? {
        if let master { return master }
        let alert = PopupAlert(); alert.messageText = title ?? (creating ? "设置主密码" : "解锁会话密码")
        let archivePassword = title?.contains("导出文件") == true
        alert.informativeText = archivePassword ? "此密码仅用于保护导出文件，不会成为 OShell 主密码；导入该文件时需要它。" : "密码密文保存在会话配置中。主密码不保存，迁移配置时也需要输入它。"
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(); field.placeholderString = archivePassword ? (creating ? "导出文件密码（至少 8 个字符）" : "导出文件密码或原主密码") : (creating ? "主密码（至少 8 个字符）" : "主密码")
        let confirm = NSSecureTextField(); confirm.placeholderString = archivePassword ? "再次输入导出文件密码" : "再次输入主密码"
        defer { field.stringValue = ""; confirm.stringValue = "" }
        let stack = NSStackView(views: creating ? [field, confirm] : [field]); stack.orientation = .vertical; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 330, height: creating ? 62 : 26)
        field.widthAnchor.constraint(equalToConstant: 330).isActive = true
        alert.accessoryView = stack; alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue
            if creating && (value.count < 8 || value != confirm.stringValue) { Dialogs.message(archivePassword ? "导出文件密码至少 8 个字符，且两次输入应一致。" : "主密码至少 8 个字符，且两次输入应一致。"); continue }
            if value.isEmpty { continue }
            return value
        }
        return nil
    }
    func encrypt(_ password: String, profile: SessionProfile, knownProfiles: [SessionProfile], identity: SSHIdentity? = nil) throws -> EncryptedPassword? {
        let prior = knownProfiles.map(currentCredential).first { $0.encryptedPassword != nil && $0.encryptedPassword?.localKeyID == nil }
        guard let candidate = requestMaster(creating: prior == nil && !masterProtectionEnabled) else { return nil }
        if let verifier {
            do { try MasterPasswordProtection.verify(verifier, password: candidate) }
            catch { lock(); throw error }
        }
        if let prior, let encrypted = prior.encryptedPassword {
            do { _ = try SessionCipher.decrypt(encrypted, master: candidate, profile: prior) }
            catch { lock(); throw error }
        }
        let identity = try identity ?? SSHIdentity.resolve(profile)
        let encrypted = try SessionCipher.encrypt(password, master: candidate, profile: profile, identity: identity)
        master = candidate; return encrypted
    }
    func decrypt(_ profile: SessionProfile, resolve: Bool = true, completion: @escaping (Result<(String, SSHIdentity), Error>) -> Void) {
        let profile = currentCredential(profile)
        guard let envelope = profile.encryptedPassword else { return }
        let candidate: String
        do {
            guard let value = try key(for: envelope) else { completion(.failure(ModelError.invalid("已取消解锁。"))); return }
            candidate = value
        } catch { completion(.failure(error)); return }
        let startedGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let resolved = try resolve ? SSHIdentity.resolve(profile) : SSHIdentity(host: profile.host, user: profile.username, port: profile.port)
                guard resolved == envelope.identity else { throw ModelError.invalid("SSH 配置解析出的目标已改变，请重新保存会话密码。") }
                let password = try SessionCipher.decrypt(envelope, master: candidate, profile: profile)
                DispatchQueue.main.async { if envelope.localKeyID == nil && self.generation == startedGeneration { self.master = candidate }; completion(.success((password, resolved))) }
            } catch { DispatchQueue.main.async { if envelope.localKeyID == nil && self.generation == startedGeneration { self.master = nil }; completion(.failure(error)) } }
        }
    }
}
