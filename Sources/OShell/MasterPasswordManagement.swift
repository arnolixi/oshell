// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class MasterPasswordDialog {
    let alert = PopupAlert()
    let old = NSSecureTextField(), next = NSSecureTextField(), confirmation = NSSecureTextField()
    init(count: Int) {
        alert.messageText = "修改主密码"
        alert.informativeText = "将重新加密 \(count) 项使用主密码保护的密码。本机自动加密不受影响；已连接会话保持连接，以前导出的文件仍使用原导出密码。"
        alert.addButton(withTitle: "修改"); alert.addButton(withTitle: "取消")
        old.placeholderString = "原主密码"; next.placeholderString = "新主密码（至少 8 个字符）"; confirmation.placeholderString = "再次输入新主密码"
        let stack = NSStackView(views: [old, next, confirmation]); stack.orientation = .vertical; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 100)
        for field in [old, next, confirmation] { field.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        alert.accessoryView = stack; alert.window.initialFirstResponder = old
    }
    func values() throws -> (old: String, next: String) {
        guard !old.stringValue.isEmpty else { throw ModelError.invalid("请填写原主密码。") }
        try ConfigurationCredentials.validateNewMaster(next.stringValue)
        guard next.stringValue == confirmation.stringValue else { throw ModelError.invalid("两次输入的新主密码不一致。") }
        guard old.stringValue != next.stringValue else { throw ModelError.invalid("新主密码不能与原主密码相同。") }
        return (old.stringValue, next.stringValue)
    }
    func clear() { old.stringValue = ""; next.stringValue = ""; confirmation.stringValue = "" }
}

extension WorkspaceController {
    @objc func changeMasterPassword() {
        guard !requiresSharingProtection else { Dialogs.message("请先停用同步并取消待生效的同步设置，再修改主密码；之后使用新的同步目录重新建立共享，原共享数据保持原密码保护。"); return }
        let count = ConfigurationCredentials.count(in: configuration)
        guard configuration.hasMasterPassword else { setupMasterPassword(); return }
        let dialog = MasterPasswordDialog(count: count); defer { dialog.clear() }
        while dialog.alert.runModal() == .alertFirstButtonReturn {
            do {
                let values = try dialog.values(), snapshot = configuration, revision = configurationRevision
                guard let result = CredentialTask.run(title: "正在修改主密码…", work: { token in
                    try ConfigurationCredentials.rotate(snapshot, oldMaster: values.old, newMaster: values.next, check: token.check)
                }) else { return }
                let rotation = try result.get()
                guard revision == configurationRevision else { throw ModelError.invalid("处理期间配置已变化，请重试。"); }
                guard saveConfiguration(rotation.configuration, updatingMasterProtection: true, storageMaster: values.next) else { return }
                PasswordVault.shared.acceptRotation(rotation, master: values.next)
                Dialogs.message("主密码已修改，使用主密码保护的密码已重新加密，本机自动加密未改变。"); return
            } catch { Dialogs.message(error.localizedDescription) }
        }
    }
}


extension WorkspaceController {
    @discardableResult func disableMasterProtection(_ password: String) throws -> Bool {
        guard !requiresSharingProtection else { throw ModelError.invalid("使用 iCloud、WebDAV 或自定义数据目录期间不能清除主密码。请先停用同步并取消待生效的同步设置。") }
        guard isSecurityUnlocked, configuration.hasMasterPassword else { return false }
        let snapshot = configuration, revision = configurationRevision
        let localStore = LocalCredentialStore(directory: store.url.deletingLastPathComponent())
        guard let result = CredentialTask.run(title: "正在清除主密码并转换保存的密码…", work: { token in
            try MasterPasswordProtection.disabling(snapshot, password: password, localKey: {
                try token.check()
                return try localStore.keyForSaving(knownProfiles: ConfigurationCredentials.profiles(in: snapshot))
            }, check: token.check)
        }) else { return false }
        let rotation = try result.get()
        guard revision == configurationRevision else { throw ModelError.invalid("处理期间配置已变化，请重试。") }
        guard saveConfiguration(rotation.configuration, updatingMasterProtection: true) else { return false }
        PasswordVault.shared.acceptMasterRemoval(rotation)
        return true
    }
    @objc func clearMasterPassword() {
        guard !requiresSharingProtection else { Dialogs.message("共享或自定义数据目录强制使用主密码，不能清除。请先停用同步并取消待生效的同步设置。"); return }
        guard isSecurityUnlocked, configuration.hasMasterPassword else { return }
        let alert = PopupAlert(); alert.alertStyle = .warning; alert.messageText = "清除主密码"
        alert.informativeText = "清除后，启动 OShell 不再要求主密码。保存的会话及代理密码将转为 OShell 本机自动加密，不使用系统钥匙串；已连接会话不受影响。\n\n本机密钥与密文同存于 OShell 数据目录，保护强度会降低。请输入当前主密码确认。"
        alert.addButton(withTitle: "清除主密码"); alert.addButton(withTitle: "取消")
        let password = NSSecureTextField(); password.placeholderString = "当前主密码"; password.identifier = .init("master.clear.current")
        let errorLabel = NSTextField(wrappingLabelWithString: ""); errorLabel.textColor = .systemRed; errorLabel.identifier = .init("master.clear.error")
        let stack = NSStackView(views: [password, errorLabel]); stack.orientation = .vertical; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 76)
        for view in [password, errorLabel] { view.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        alert.accessoryView = stack; alert.window.initialFirstResponder = password
        defer { password.stringValue = "" }
        while alert.runModal() == .alertFirstButtonReturn {
            let candidate = password.stringValue; password.stringValue = ""
            guard !candidate.isEmpty else { errorLabel.stringValue = "请输入当前主密码。"; continue }
            do { if try disableMasterProtection(candidate) { return }; return }
            catch { errorLabel.stringValue = error.localizedDescription }
        }
    }
}
