// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

extension WorkspaceController {
    /// Called only after the protected LocalCommand readiness signal. Encryption
    /// runs off the main thread without nesting another modal authentication loop.
    func saveAuthenticatedPassword(_ password: String, profile original: SessionProfile,
                                   identity: SSHIdentity, requireExisting: Bool, completion: @escaping (Bool) -> Void) {
        guard isSecurityUnlocked, original.kind == .ssh else { completion(false); return }
        do {
            let current = configuration.profiles.first { $0.id == original.id }
            if requireExisting && current == nil { throw ModelError.invalid("会话配置已删除，未重新创建或保存密码。") }
            if let current {
                guard current.kind == original.kind, current.host == original.host, current.port == original.port,
                      current.username == original.username, current.encryptedPassword == original.encryptedPassword else {
                    throw ModelError.invalid("会话连接信息或已保存密码已变化，未覆盖当前配置。")
                }
            }
            var target = current ?? original
            if target.username.isEmpty { target.username = identity.user }
            let secret: String, localID: UUID?
            if configuration.hasMasterPassword {
                guard let master = PasswordVault.shared.cachedMaster else { completion(false); return }
                secret = master; localID = nil
            } else {
                let key = try PasswordVault.shared.localKeyForSaving(knownProfiles: credentialProfiles)
                secret = key.secret; localID = key.id
            }
            let revision = configurationRevision, snapshot = configuration, destination = target
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result: Result<EncryptedPassword, Error> = Result {
                    if localID == nil { try MasterPasswordProtection.verifyStartup(snapshot, password: secret) }
                    var envelope = try SessionCipher.encrypt(password, master: secret, profile: destination, identity: identity)
                    envelope.localKeyID = localID; return envelope
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isSecurityUnlocked else { completion(false); return }
                    do {
                        guard self.configurationRevision == revision else { throw ModelError.invalid("保存期间配置已变化，未覆盖当前配置。") }
                        var saved = destination; saved.encryptedPassword = try result.get()
                        var value = self.configuration
                        if let index = value.profiles.firstIndex(where: { $0.id == saved.id }) { value.profiles[index] = saved }
                        else { value.profiles.append(saved) }
                        completion(self.saveConfiguration(value))
                    } catch { completion(false); Dialogs.message("SSH 已完成认证，但密码未保存：\(error.localizedDescription)") }
                }
            }
        } catch { completion(false); Dialogs.message("SSH 已完成认证，但密码未保存：\(error.localizedDescription)") }
    }
}
