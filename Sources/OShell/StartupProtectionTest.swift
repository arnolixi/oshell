// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum StartupProtectionTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool]()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func drive(_ action: @escaping (NSWindow, [NSView]) -> Void, work: () -> Void) {
            let timer = Timer(timeInterval: 0.04, repeats: true) { _ in
                if let modal = NSApp.modalWindow, let root = modal.contentView { action(modal, views(root)) }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
            work(); timer.invalidate()
        }
        do {
            checks["noMasterNoStartupDialog"] = controller.unlockAtStartup() && NSApp.modalWindow == nil
            checks["warningAndSetupVisible"] = !controller.masterWarning.isHidden && views(controller.masterWarning).contains { $0.identifier?.rawValue == "master.setup" }
            let dismiss = views(controller.masterWarning).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "master.warning.dismiss" }
            dismiss?.performClick(nil)
            checks["warningDismissButtonPersistsChoice"] = try dismiss?.title == "我已知晓，不再提醒" && controller.store.load().preferences.masterWarningAcknowledged
            checks["dismissHidesWholeWarningRow"] = controller.masterWarning.isHidden && controller.masterWarningHeight.constant == 0
            let dismissedRestart = WorkspaceController(store: controller.store)
            checks["dismissSurvivesRestart"] = dismissedRestart.masterWarning.isHidden && dismissedRestart.unlockAtStartup()
            let oldPreferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
            checks["oldConfigurationStillShowsWarning"] = !oldPreferences.masterWarningAcknowledged
            let master = "startup-fixture-master", next = "changed-fixture-master"
            var local = SessionProfile(name: "本机密码测试", host: "192.0.2.10", username: "fixture")
            let key = try PasswordVault.shared.localKeyForSaving(knownProfiles: [])
            var encrypted = try SessionCipher.encrypt("fixture-secret", master: key.secret, profile: local, identity: SSHIdentity(host: local.host, user: local.username, port: local.port))
            encrypted.localKeyID = key.id; local.encryptedPassword = encrypted
            var localConfiguration = controller.configuration; localConfiguration.profiles = [local]
            checks["localFixtureSaved"] = controller.saveConfiguration(localConfiguration)
            var submitted = false
            drive({ _, all in
                guard !submitted, let field = all.first(where: { $0.identifier?.rawValue == "master.new" }) as? NSSecureTextField,
                      let confirm = all.first(where: { $0.identifier?.rawValue == "master.confirm" }) as? NSSecureTextField else { return }
                field.stringValue = master; confirm.stringValue = master; submitted = true
                all.compactMap { $0 as? NSButton }.first { $0.title == "设置" }?.performClick(nil)
            }, work: { controller.setupMasterPassword() })
            checks["setupPersistsAndHidesWarning"] = controller.configuration.masterPasswordVerifier != nil && controller.masterWarning.isHidden
            let profile = controller.configuration.profiles[0]
            checks["localCredentialMigrated"] = try profile.encryptedPassword?.localKeyID == nil && (SessionCipher.decrypt(profile.encryptedPassword!, master: master, profile: profile)) == "fixture-secret"
            checks["oldSnapshotResolvesAfterSetup"] = PasswordVault.shared.currentCredential(local).encryptedPassword == profile.encryptedPassword
            do { _ = try PasswordVault.shared.protect("value", profile: local, knownProfiles: [], protection: .local); checks["localDowngradeBlocked"] = false }
            catch { checks["localDowngradeBlocked"] = true }
            let verifier = controller.configuration.masterPasswordVerifier
            var emptyConfiguration = controller.configuration; emptyConfiguration.profiles = []; emptyConfiguration.masterPasswordVerifier = nil
            checks["staleSaveAccepted"] = controller.saveConfiguration(emptyConfiguration)
            checks["deletingAllSessionsKeepsProtection"] = controller.configuration.masterPasswordVerifier == verifier && controller.configuration.hasMasterPassword
            PasswordVault.shared.lock()
            let restarted = WorkspaceController(store: controller.store)
            var delivery: Bool?
            restarted.whenStartupUnlocked { delivery = $0 }
            restarted.show(); restarted.open(.local)
            checks["lockedWorkspaceAndConnectionsBlocked"] = restarted.window?.isVisible == false && restarted.tabs.isEmpty && delivery == nil
            var attempts = 0, unlocked = false
            drive({ _, all in
                guard let field = all.first(where: { $0.identifier?.rawValue == "master.unlock" }) as? NSSecureTextField else { return }
                let error = (all.first { $0.identifier?.rawValue == "master.error" } as? NSTextField)?.stringValue ?? ""
                if attempts == 0 || (attempts == 1 && !error.isEmpty) {
                    if attempts == 1 { checks["wrongMasterRemainsLocked"] = !restarted.isSecurityUnlocked && delivery == nil && restarted.window?.isVisible == false }
                    field.stringValue = attempts == 0 ? "wrong-fixture" : master; attempts += 1
                    all.compactMap { $0 as? NSButton }.first { $0.title == "解锁" }?.performClick(nil)
                }
            }, work: { unlocked = restarted.unlockAtStartup() })
            checks["correctMasterReleasesStartupQueue"] = unlocked && delivery == true && attempts == 2
            let rotation = try ConfigurationCredentials.rotate(restarted.configuration, oldMaster: master, newMaster: next)
            checks["rotateWithNoSessions"] = restarted.saveConfiguration(rotation.configuration, updatingMasterProtection: true)
            PasswordVault.shared.acceptRotation(rotation, master: next)
            let cancelled = WorkspaceController(store: controller.store)
            var rejected: Bool?, cancelledResult = true
            cancelled.whenStartupUnlocked { rejected = $0 }
            drive({ window, all in
                if all.contains(where: { $0.identifier?.rawValue == "master.unlock" }) { _ = PopupKeyboard.dismiss(window: window) }
            }, work: { cancelledResult = cancelled.unlockAtStartup() })
            checks["escapeRejectsStartupAndQueuedRequests"] = !cancelledResult && rejected == false && !cancelled.isSecurityUnlocked && cancelled.window?.isVisible == false
            let saved = try controller.store.load()
            checks["oldPasswordRejectedAfterRotation"] = (try? MasterPasswordProtection.verifyStartup(saved, password: master)) == nil
            try MasterPasswordProtection.verifyStartup(saved, password: next)
            checks["newPasswordWorksAfterRotation"] = true
            let plain = String(decoding: try Data(contentsOf: controller.store.url), as: UTF8.self)
            checks["noPlaintextMasterOnDisk"] = !plain.contains(master) && !plain.contains(next) && !plain.contains("fixture-secret")
            let emptyStore = ConfigurationStore(directory: controller.store.url.deletingLastPathComponent().appendingPathComponent("empty"))
            let empty = WorkspaceController(store: emptyStore)
            checks["canSetMasterWithoutSavedCredentials"] = try empty.enableMasterProtection(master)
            checks["emptyStoreRequiresMasterAfterRestart"] = !WorkspaceController(store: emptyStore).isSecurityUnlocked
        } catch { checks["unexpectedError"] = false; print("Startup protection test error: \(error.localizedDescription)") }
        let output = ProcessInfo.processInfo.environment["OSHELL_STARTUP_PROTECTION_OUTPUT"] ?? "/tmp/oshell-startup-protection.json"
        let report: [String: Any] = ["ok": checks.values.allSatisfy { $0 }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        NSApp.terminate(nil)
    }
}
