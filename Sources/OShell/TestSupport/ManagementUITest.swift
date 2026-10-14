// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum ManagementUITest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) } }
        do {
            var profile = SessionProfile(name: "迁移测试", group: "目录/子目录", host: "example.test", username: "ops")
            profile.encryptedPassword = try SessionCipher.encrypt("only-test-secret", master: "old-master-123", profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
            PasswordVault.shared.unlockForTesting("old-master-123")
            let original = Configuration(profiles: [profile]); checks["fixtureSaved"] = controller.saveConfiguration(original)
            let saved = try Data(contentsOf: controller.store.url)
            let menu = NSApp.mainMenu.map(menuItems) ?? []
            checks["masterMenuEntry"] = menu.contains { $0.action == #selector(WorkspaceController.changeMasterPassword) }
            checks["importExportMenuEntries"] = menu.contains { $0.action == #selector(WorkspaceController.importSessions) } && menu.contains { $0.action == #selector(WorkspaceController.exportSessions) }
            let manager = SessionManager(workspace: controller); manager.show()
            let rootTitles = manager.contextMenu(for: 0).items.map(\.title)
            checks["directoryExportContext"] = rootTitles.contains("导出此目录…")
            manager.reveal(profile)
            let sessionTitles = manager.contextMenu(for: 1).items.map(\.title)
            checks["sessionExportContext"] = sessionTitles.contains("导出此会话…")
            let parentTitles = manager.contextMenu(for: 0).items.map(\.title)
            checks["parentNotExportedAsSession"] = !parentTitles.contains("导出此会话…") && !parentTitles.contains("导出此目录…")
            let blankTitles = manager.contextMenu(for: -1).items.map(\.title)
            checks["blankImportExportContext"] = blankTitles.contains("导出全部会话…") && blankTitles.contains("导入会话到当前目录…")
            let buttons = descendants(manager.window!.contentView!).compactMap { ($0 as? NSButton)?.title }
            checks["noNewHeaderOperationButtons"] = !buttons.contains(where: { $0.contains("导出") || $0.contains("导入") })
            manager.close()

            let dialog = MasterPasswordDialog(count: 1)
            dialog.old.stringValue = "old-master-123"; dialog.next.stringValue = "short"; dialog.confirmation.stringValue = "short"
            checks["rejectShortMaster"] = (try? dialog.values()) == nil
            dialog.next.stringValue = "new-master-456"; dialog.confirmation.stringValue = "different"
            checks["rejectMismatchedConfirmation"] = (try? dialog.values()) == nil
            dialog.confirmation.stringValue = "new-master-456"; checks["acceptValidFields"] = (try? dialog.values()) != nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { _ = PopupKeyboard.dismiss(window: dialog.alert.window) }
            checks["masterDialogEscapeCancels"] = dialog.alert.runModal() == .alertSecondButtonReturn
            dialog.clear(); checks["passwordFieldsCleared"] = [dialog.old, dialog.next, dialog.confirmation].allSatisfy { $0.stringValue.isEmpty }
            checks["dialogCancelKeepsDisk"] = try Data(contentsOf: controller.store.url) == saved

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
            let cancelled: Result<Int, Error>? = CredentialTask.run(title: "取消检查") { token in
                for _ in 0..<50 { Thread.sleep(forTimeInterval: 0.01); try token.check() }; return 1
            }
            checks["cryptoTaskEscapeCancels"] = cancelled == nil
            checks["taskCancelKeepsDisk"] = try Data(contentsOf: controller.store.url) == saved

            // Drive the real menu action through secure fields, background crypto and disk commit.
            var finished = false, submitted = false, successMessage = false
            func drive() {
                guard !finished else { return }
                if let window = NSApp.modalWindow, let root = window.contentView {
                    let fields = descendants(root).compactMap { $0 as? NSSecureTextField }
                    if fields.count == 3 && !submitted {
                        for field in fields {
                            field.stringValue = field.placeholderString == "原主密码" ? "old-master-123" : "new-master-456"
                        }
                        submitted = true
                        descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "修改" }?.performClick(nil)
                    } else if descendants(root).compactMap({ ($0 as? NSTextField)?.stringValue }).contains(where: { $0.contains("主密码已修改") }) {
                        successMessage = true; _ = PopupKeyboard.dismiss(window: window)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { drive() }
            }
            DispatchQueue.main.async { drive() }
            controller.changeMasterPassword(); finished = true
            checks["realChangeActionCompleted"] = successMessage
            let loaded = try controller.store.load()
            checks["newMasterDecryptsDisk"] = (try? ConfigurationCredentials.verify(loaded, master: "new-master-456")) != nil
            checks["oldMasterCannotDecryptDisk"] = (try? ConfigurationCredentials.verify(loaded, master: "old-master-123")) == nil
            let snapshot = PasswordVault.shared.currentCredential(profile)
            checks["openSnapshotUpdated"] = (try? SessionCipher.decrypt(snapshot.encryptedPassword!, master: "new-master-456", profile: snapshot)) == "only-test-secret"
            checks["staleEditorSnapshotSaved"] = controller.saveConfiguration(original)
            checks["staleEditorCannotRestoreOldCipher"] = (try? ConfigurationCredentials.verify(controller.store.load(), master: "new-master-456")) != nil
            let archive = SessionArchive(profiles: [profile], directories: ["目录/空目录"], includePasswords: true)
            let archiveURL = controller.store.url.deletingLastPathComponent().appendingPathComponent("sessions.oshell.json")
            try PrivateFile.write(archive.encoded(), to: archiveURL)
            var importFinished = false, importSucceeded = false
            func driveImport() {
                guard !importFinished else { return }
                if let window = NSApp.modalWindow, let root = window.contentView {
                    let fields = descendants(root).compactMap { $0 as? NSSecureTextField }
                    let buttons = descendants(root).compactMap { $0 as? NSButton }
                    if let importButton = buttons.first(where: { $0.title == "导入" }) { importButton.performClick(nil) }
                    else if fields.count == 1 {
                        fields[0].stringValue = "old-master-123"; buttons.first { $0.title == "确定" }?.performClick(nil)
                    } else if descendants(root).compactMap({ ($0 as? NSTextField)?.stringValue }).contains(where: { $0.contains("已导入 1 个会话") }) {
                        importSucceeded = true; _ = PopupKeyboard.dismiss(window: window)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { driveImport() }
            }
            DispatchQueue.main.async { driveImport() }
            SessionTransfer.importArchive(at: archiveURL, workspace: controller, directory: "")
            importFinished = true
            checks["realImportActionCompleted"] = importSucceeded
            let imported = try controller.store.load()
            checks["importActionAppendsCopy"] = imported.profiles.count == 2 && imported.profiles.last?.name == "迁移测试（导入副本）"
            checks["importActionRetainsEmptyDirectory"] = imported.directories.contains("目录/空目录")
            checks["importActionUsesLocalMaster"] = (try? ConfigurationCredentials.verify(imported, master: "new-master-456")) != nil
            let second = try ConfigurationCredentials.rotate(loaded, oldMaster: "new-master-456", newMaster: "third-master-789")
            PasswordVault.shared.acceptRotation(second, master: "third-master-789"); PasswordVault.shared.lock()
            let twice = PasswordVault.shared.currentCredential(profile)
            checks["snapshotSurvivesTwoRotationsAndLock"] = (try? SessionCipher.decrypt(twice.encryptedPassword!, master: "third-master-789", profile: twice)) == "only-test-secret"
        } catch { checks["unexpectedError"] = false; print("Management UI test error: \(error.localizedDescription)") }
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        let path = ProcessInfo.processInfo.environment["OSHELL_MANAGEMENT_OUTPUT"] ?? "/tmp/oshell-management-ui.json"
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        print(report); controller.shutdown(); NSApp.terminate(nil)
    }
}
