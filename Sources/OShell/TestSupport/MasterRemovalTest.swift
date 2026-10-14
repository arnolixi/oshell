// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum MasterRemovalTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool]()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func drive(_ action: @escaping (NSWindow, [NSView]) -> Void, work: () throws -> Void) rethrows {
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                if let window = NSApp.modalWindow, let root = window.contentView { action(window, views(root)) }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }; try work()
        }
        do {
            let master = "remove-fixture-master", next = "reset-fixture-master"
            var profile = SessionProfile(name: "保留密码", host: "192.0.2.42", username: "fixture")
            profile.encryptedPassword = try SessionCipher.encrypt("saved-fixture-secret", master: master, profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
            var configuration = Configuration(profiles: [profile]); configuration.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
            checks["fixtureSaved"] = controller.saveConfiguration(configuration, updatingMasterProtection: true)
            PasswordVault.shared.acceptMaster(master)
            controller.newLocal(); let pane = controller.selectedTab!.activePane, pid = pane.terminal.process.shellPid
            let originalBytes = try Data(contentsOf: controller.store.url)
            let menu = NSMenuItem(title: "清除主密码…", action: #selector(WorkspaceController.clearMasterPassword), keyEquivalent: "")
            checks["clearEnabledWithMaster"] = controller.validateMenuItem(menu)
            drive({ window, all in
                if all.contains(where: { $0.identifier?.rawValue == "master.clear.current" }) { _ = PopupKeyboard.dismiss(window: window) }
            }, work: { controller.clearMasterPassword() })
            checks["escapeKeepsProtectionAndDisk"] = try controller.configuration.hasMasterPassword && Data(contentsOf: controller.store.url) == originalBytes
            var submitted = false, cancelledWork = false
            drive({ window, all in
                if !submitted, let field = all.first(where: { $0.identifier?.rawValue == "master.clear.current" }) as? NSSecureTextField {
                    field.stringValue = master; submitted = true
                    all.compactMap { $0 as? NSButton }.first { $0.title == "清除主密码" }?.performClick(nil)
                } else if all.contains(where: { $0 is NSProgressIndicator }) {
                    cancelledWork = true; _ = PopupKeyboard.dismiss(window: window)
                }
            }, work: { controller.clearMasterPassword() })
            checks["cancelEncryptionKeepsProtectionAndDisk"] = try cancelledWork && controller.configuration.hasMasterPassword && Data(contentsOf: controller.store.url) == originalBytes
            // Force the atomic config commit to fail while preserving the fixture in a sibling file.
            let backup = controller.store.url.appendingPathExtension("test-backup")
            try FileManager.default.moveItem(at: controller.store.url, to: backup)
            try FileManager.default.createDirectory(at: controller.store.url, withIntermediateDirectories: false)
            var failedCommitResult = true, sawSaveError = false
            try drive({ window, all in
                if all.compactMap({ ($0 as? NSTextField)?.stringValue }).contains(where: { $0.contains("保存配置失败") }) {
                    sawSaveError = true; _ = PopupKeyboard.dismiss(window: window)
                }
            }, work: { failedCommitResult = try controller.disableMasterProtection(master) })
            try FileManager.default.removeItem(at: controller.store.url); try FileManager.default.moveItem(at: backup, to: controller.store.url)
            checks["saveFailureKeepsRuntimeProtection"] = sawSaveError && !failedCommitResult && controller.configuration.hasMasterPassword && PasswordVault.shared.cachedMaster == master
            checks["saveFailureKeepsOriginalCredentials"] = try Data(contentsOf: controller.store.url) == originalBytes
            var attempts = 0
            drive({ _, all in
                guard let field = all.first(where: { $0.identifier?.rawValue == "master.clear.current" }) as? NSSecureTextField else { return }
                let error = (all.first { $0.identifier?.rawValue == "master.clear.error" } as? NSTextField)?.stringValue ?? ""
                if attempts == 0 || (attempts == 1 && !error.isEmpty) {
                    if attempts == 1 {
                        checks["wrongMasterDoesNotClear"] = controller.configuration.hasMasterPassword && (try? Data(contentsOf: controller.store.url)) == originalBytes
                        checks["submittedPasswordCleared"] = field.stringValue.isEmpty
                    }
                    field.stringValue = attempts == 0 ? "wrong-fixture" : master; attempts += 1
                    all.compactMap { $0 as? NSButton }.first { $0.title == "清除主密码" }?.performClick(nil)
                }
            }, work: { controller.clearMasterPassword() })
            checks["correctPasswordClearsMaster"] = attempts == 2 && !controller.configuration.hasMasterPassword && controller.configuration.masterPasswordVerifier == nil
            checks["warningRestoredAndMenuDisabled"] = !controller.masterWarning.isHidden && !controller.validateMenuItem(menu)
            checks["cachedMasterRemoved"] = PasswordVault.shared.cachedMaster == nil && !PasswordVault.shared.masterProtectionEnabled
            checks["runningSessionUnchanged"] = controller.selectedTab?.activePane === pane && pane.terminal.process.shellPid == pid && pane.terminal.process.running && !pane.isShutdown
            let key = try LocalCredentialStore(directory: controller.store.url.deletingLastPathComponent()).load()
            let saved = controller.configuration.profiles[0]
            checks["savedPasswordUsesLocalKey"] = saved.encryptedPassword?.localKeyID == key.id
            checks["oldSessionSnapshotStillReadsPassword"] = try PasswordVault.shared.readSavedPassword(profile) == "saved-fixture-secret"
            checks["staleConfigCanBeSaved"] = controller.saveConfiguration(configuration)
            checks["staleSaveDoesNotRestoreMaster"] = !controller.configuration.hasMasterPassword && controller.configuration.profiles[0].encryptedPassword?.localKeyID == key.id
            let restarted = WorkspaceController(store: controller.store)
            checks["restartWithoutUnlockDialog"] = restarted.unlockAtStartup() && NSApp.modalWindow == nil && !restarted.configuration.hasMasterPassword
            checks["passwordReadableAfterRestart"] = try PasswordVault.shared.readSavedPassword(restarted.configuration.profiles[0]) == "saved-fixture-secret"
            checks["reenableMasterWorks"] = try controller.enableMasterProtection(next)
            try ConfigurationCredentials.verify(controller.configuration, master: next)
            checks["clearAgainWorks"] = try controller.disableMasterProtection(next)
            checks["snapshotSurvivesRepeatedModeChanges"] = try PasswordVault.shared.readSavedPassword(profile) == "saved-fixture-secret"
            checks["localKeyReused"] = try LocalCredentialStore(directory: controller.store.url.deletingLastPathComponent()).load().id == key.id
            checks["removeLastSession"] = controller.saveConfiguration(Configuration(profiles: []))
            checks["emptyVaultSetup"] = try controller.enableMasterProtection(master)
            checks["emptyVaultClear"] = try controller.disableMasterProtection(master)
            checks["emptyVaultNoMasterAfterRestart"] = !WorkspaceController(store: controller.store).configuration.hasMasterPassword
            let encoded = String(decoding: originalBytes, as: UTF8.self)
            checks["fixtureContainsNoPlaintext"] = !encoded.contains("saved-fixture-secret") && !encoded.contains(master)
        } catch { checks["unexpectedError"] = false; print("Master removal test: \(error.localizedDescription)") }
        let path = ProcessInfo.processInfo.environment["OSHELL_MASTER_REMOVAL_OUTPUT"] ?? "/tmp/oshell-master-removal.json"
        try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path))
        controller.shutdown(); NSApp.terminate(nil)
    }
}
