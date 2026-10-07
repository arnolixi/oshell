// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import UniformTypeIdentifiers
import OShellCore

enum SessionTransfer {
    static func export(profiles: [SessionProfile], directories: [String]) {
        let currentProfiles = PasswordVault.shared.currentCredentials(in: Configuration(profiles: profiles)).profiles
        let hasLocal = currentProfiles.contains { $0.encryptedPassword?.localKeyID != nil || $0.proxy.encryptedPassword?.localKeyID != nil }
        let options = PopupAlert(); options.messageText = "导出会话"
        options.informativeText = "导出 \(profiles.count) 个会话及目录结构。包含代理、隧道、保活等连接设置；不包含私钥文件、主机指纹或终端历史。"
        options.addButton(withTitle: "选择保存位置…"); options.addButton(withTitle: "取消")
        let passwords = NSButton(checkboxWithTitle: hasLocal ? "包含已保存密码（单独设置导出文件密码）" : "包含已保存的加密密码（导入时需要原主密码）", target: nil, action: nil)
        passwords.frame = NSRect(x: 0, y: 0, width: 420, height: 26); passwords.state = .off; options.accessoryView = passwords
        guard options.runModal() == .alertFirstButtonReturn else { return }
        do {
            var archive = SessionArchive(profiles: currentProfiles, directories: directories, includePasswords: passwords.state == .on)
            if passwords.state == .on && hasLocal {
                guard let exportPassword = PasswordVault.promptMaster(title: "设置导出文件密码", creating: true),
                      let keys = try PasswordVault.shared.credentialKeys(for: currentProfiles + currentProfiles.map { $0.proxy.credentialProfile }) else { return }
                let source = archive
                guard let result = CredentialTask.run(title: "加密导出密码…", work: { token in
                    try source.protectedForExport(password: exportPassword, credentialKey: { profile in
                        guard let envelope = profile.encryptedPassword, let key = keys[envelope.ciphertext] else { throw ModelError.invalid("缺少导出所需的解密密钥。"); }; return key
                    }, check: token.check)
                }) else { return }
                archive = try result.get()
            }
            let data = try archive.encoded()
            let panel = NSSavePanel(); panel.title = "导出 OShell 会话"; panel.oshellJSONFilesOnly()
            panel.nameFieldStringValue = "OShell-sessions.oshell.json"; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try PrivateFile.write(data, to: url)
            Dialogs.message("已导出 \(archive.profiles.count) 个会话。" + (archive.passwordCount > 0 ? (hasLocal ? "导入时使用刚设置的导出文件密码；本机密钥没有导出。" : "导入加密密码时请使用此次导出时的主密码。") : "文件未包含已保存密码。"))
        } catch { Dialogs.message("导出失败：\(error.localizedDescription)") }
    }

    static func importSessions(workspace: WorkspaceController, directory: String) {
        let panel = NSOpenPanel(); panel.title = "导入 OShell 会话"; panel.oshellJSONFilesOnly()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importArchive(at: url, workspace: workspace, directory: directory)
    }

    static func importArchive(at url: URL, workspace: WorkspaceController, directory: String) {
        do {
            let archive = try SessionArchive.read(url)
            let preview = PopupAlert(); preview.messageText = "导入 \(archive.profiles.count) 个会话"
            preview.informativeText = "目标：\(directory.isEmpty ? "所有会话" : directory)。保留文件中的目录层级，包括空目录。同名会话另存为“导入副本”，现有会话和设置保留。导入后不会自动连接。"
            preview.addButton(withTitle: "导入"); preview.addButton(withTitle: "取消")
            let passwords = NSButton(checkboxWithTitle: "导入 \(archive.passwordCount) 项加密密码", target: nil, action: nil)
            passwords.state = archive.passwordCount > 0 ? .on : .off; passwords.isEnabled = archive.passwordCount > 0
            let protection = NSPopUpButton(); protection.addItems(withTitles: PasswordProtection.allCases.map(\.title))
            protection.selectItem(at: workspace.configuration.hasMasterPassword ? 1 : 0)
            protection.isEnabled = archive.passwordCount > 0
            if workspace.configuration.hasMasterPassword { protection.autoenablesItems = false; protection.item(at: 0)?.isEnabled = false }
            let choices = NSStackView(views: [passwords, protection]); choices.orientation = .vertical; choices.alignment = .leading; choices.spacing = 10
            choices.frame = NSRect(x: 0, y: 0, width: 450, height: 64); preview.accessoryView = choices
            guard preview.runModal() == .alertFirstButtonReturn else { return }
            let include = passwords.state == .on
            var sourceMaster: String?, destinationMaster: String?, destinationLocalKeyID: UUID?
            if include {
                guard let source = PasswordVault.promptMaster(title: "输入导出文件密码或原主密码", creating: false) else { return }
                sourceMaster = source
                if protection.indexOfSelectedItem == 0 {
                    let key = try PasswordVault.shared.localKeyForSaving(knownProfiles: workspace.credentialProfiles)
                    destinationMaster = key.secret; destinationLocalKeyID = key.id
                } else {
                    guard let destination = PasswordVault.shared.masterForImport(hasSavedPasswords: workspace.configuration.hasMasterPassword) else { return }
                    destinationMaster = destination
                }
            }
            let snapshot = workspace.configuration, revision = workspace.configurationRevision
            var localKeys = [String: String]()
            if destinationLocalKeyID == nil, let destinationMaster {
                for profile in ConfigurationCredentials.profiles(in: snapshot) {
                    if let envelope = profile.encryptedPassword, envelope.localKeyID != nil {
                        localKeys[envelope.ciphertext] = try PasswordVault.shared.migrationKey(profile, master: destinationMaster)
                    }
                }
            }
            let migrationKeys = localKeys
            guard let result = CredentialTask.run(title: "正在导入会话…", work: { token in
                var merged = try archive.merging(into: snapshot, directory: directory, includePasswords: include,
                                    sourceMaster: sourceMaster, destinationMaster: destinationMaster, destinationLocalKeyID: destinationLocalKeyID, check: token.check)
                var migration: CredentialRotation?
                if destinationLocalKeyID == nil, let destinationMaster {
                    migration = try MasterPasswordProtection.enabling(merged, password: destinationMaster, credentialKey: { profile in
                        guard let cipher = profile.encryptedPassword?.ciphertext, let key = migrationKeys[cipher] else { throw ModelError.invalid("缺少本机加密密钥。") }
                        return key
                    }, check: token.check)
                    merged = migration!.configuration
                }
                return (merged, migration)
            }) else { return }
            let (updated, migration) = try result.get()
            guard revision == workspace.configurationRevision else { throw ModelError.invalid("处理期间配置已变化，请重新导入。") }
            guard workspace.saveConfiguration(updated, updatingMasterProtection: true) else { return }
            if destinationLocalKeyID == nil, let destinationMaster {
                if let migration { PasswordVault.shared.acceptRotation(migration, master: destinationMaster) }
                else { PasswordVault.shared.acceptMaster(destinationMaster) }
            }
            Dialogs.message("已导入 \(archive.profiles.count) 个会话，原有会话已保留。")
        } catch { Dialogs.message("导入失败，未修改配置：\(error.localizedDescription)") }
    }
}
