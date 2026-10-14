// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum LocalPasswordFeatureTest {
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_IDENTITY_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        var checks = [String: Bool](), finished = false, allowMaster = false
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func later(_ action: @escaping () -> Void) {
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in action() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
        }
        let guardTimer = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard !allowMaster, let window = NSApp.modalWindow, let view = window.contentView else { return }
            if descendants(view).compactMap({ $0 as? NSSecureTextField }).contains(where: { $0.placeholderString?.contains("主密码") == true }) {
                checks["noUnexpectedMasterPrompt"] = false; _ = PopupKeyboard.dismiss(window: window)
            }
        }
        RunLoop.main.add(guardTimer, forMode: .common); RunLoop.main.add(guardTimer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
        func finish() {
            guard !finished else { return }; finished = true; guardTimer.invalidate()
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
            controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(15)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; next() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll) }
            }; poll()
        }
        do {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
            let password = fixture["password"] as! String, port = fixture["outerPort"] as! Int
            try controller.store.save(controller.configuration)
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
            PasswordVault.shared.lock(); checks["noUnexpectedMasterPrompt"] = true
            let editor = SessionEditor(nil, profiles: controller.credentialProfiles, directories: [], initialDirectory: "测试")
            let view = editor.dialog.accessoryView!
            func field(_ id: String) -> NSTextField { descendants(view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id }! }
            field("session.name").stringValue = "本机密码测试"; field("session.host").stringValue = "127.0.0.1"
            field("session.port").stringValue = String(port); field("session.user").stringValue = "test"; field("session.password").stringValue = password
            let remember = descendants(view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "session.remember" }!
            remember.performClick(nil)
            let protection = descendants(view).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "session.passwordProtection" }!
            checks["newSaveDefaultsToLocal"] = protection.indexOfSelectedItem == 0 && protection.isEnabled
            later { editor.dialog.buttons.first?.performClick(nil) }
            guard let saved = editor.run() else { checks["saveEditor"] = false; finish(); return }
            checks["editorSavedLocalEnvelope"] = saved.encryptedPassword?.localKeyID != nil
            var config = controller.configuration; config.profiles.append(saved)
            checks["saveConfiguration"] = controller.saveConfiguration(config)
            let keyStore = LocalCredentialStore(directory: controller.store.url.deletingLastPathComponent()), key = try keyStore.load()
            let file = try String(contentsOf: controller.store.url, encoding: .utf8)
            checks["configurationHasNoPlainPasswordOrKey"] = !file.contains(password) && !file.contains(key.secret)
            checks["masterNotRequiredForLocalRecords"] = ConfigurationCredentials.count(in: controller.configuration) == 0
            PasswordVault.shared.lock()
            checks["localReadWorksAfterMasterLock"] = try PasswordVault.shared.readSavedPassword(saved) == password
            guard let copy = controller.duplicateSavedSession(saved.id) else { checks["copy"] = false; finish(); return }
            checks["copyKeepsLocalMode"] = copy.encryptedPassword?.localKeyID == key.id
            checks["copyDecryptsWithoutMaster"] = try PasswordVault.shared.readSavedPassword(copy) == password
            var proxy = ProxySettings(); proxy.kind = .socks5; proxy.host = "127.0.0.1"; proxy.username = "proxy-fixture"
            proxy.encryptedPassword = try PasswordVault.shared.protect("proxy-only-fixture", profile: proxy.credentialProfile, knownProfiles: controller.credentialProfiles, protection: .local, identity: SSHIdentity(host: proxy.host, user: proxy.username, port: proxy.port))
            let proxySecret = try PasswordVault.shared.readSavedPassword(proxy.credentialProfile)
            checks["proxyUsesSameLocalProtection"] = proxy.encryptedPassword?.localKeyID == key.id && proxySecret == "proxy-only-fixture"
            var legacy = saved; legacy.id = UUID(); legacy.name = "原主密码模式"
            legacy.encryptedPassword = try SessionCipher.encrypt(password, master: "old-master-fixture", profile: legacy, identity: saved.encryptedPassword!.identity)
            allowMaster = true; PasswordVault.shared.lock()
            let migration = SessionEditor(legacy, profiles: controller.credentialProfiles + [legacy], directories: [], initialDirectory: "")
            let selector = descendants(migration.dialog.accessoryView!).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "session.passwordProtection" }!
            checks["existingMasterModePreserved"] = selector.indexOfSelectedItem == 1
            var unlockCount = 0
            let unlockTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
                guard let window = NSApp.modalWindow, window !== migration.dialog.window, let root = window.contentView,
                      let field = descendants(root).compactMap({ $0 as? NSSecureTextField }).first(where: { $0.placeholderString == "主密码" }) else { return }
                unlockCount += 1; field.stringValue = "old-master-fixture"
                descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "确定" }?.performClick(nil)
            }
            RunLoop.main.add(unlockTimer, forMode: .common); RunLoop.main.add(unlockTimer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
            selector.selectItem(at: 0); later { migration.dialog.buttons.first?.performClick(nil) }
            let converted = migration.run()
            unlockTimer.invalidate(); checks["conversionUnlocksOldMasterOnce"] = unlockCount == 1
            checks["masterCanConvertWithoutRetypingSSHPassword"] = converted?.encryptedPassword?.localKeyID == key.id
            PasswordVault.shared.lock(); allowMaster = false
            if let converted { checks["convertedPasswordReadsWithoutMaster"] = try PasswordVault.shared.readSavedPassword(converted) == password }
            checks["keyNotRegenerated"] = try keyStore.load() == key
            let before = try Data(contentsOf: controller.store.url)
            let cancelled = SessionEditor(saved, profiles: controller.credentialProfiles, directories: [], initialDirectory: "")
            later { _ = PopupKeyboard.dismiss(window: cancelled.dialog.window) }
            let cancelledResult = cancelled.run(), afterCancel = try Data(contentsOf: controller.store.url)
            checks["cancelLeavesConfigurationIntact"] = cancelledResult == nil && afterCancel == before
            PasswordVault.shared.configureLocalStorage(directory: controller.store.url.deletingLastPathComponent()); PasswordVault.shared.lock()
            let restored = try controller.store.load().profiles.first { $0.id == saved.id }!
            controller.open(restored); let pane = controller.selectedTab!.activePane
            wait("realSSHAuthenticatesWithoutMaster", { pane.sessionReady && pane.title == "outer-real" }) {
                pane.sendManaged(Array("echo LOCAL_PASSWORD_AUTH_OK\r".utf8))
                wait("authenticatedShellAcceptsCommands", { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("\nLOCAL_PASSWORD_AUTH_OK\n") }) { finish() }
            }
        } catch { checks["setupOrCrypto"] = false; finish() }
    }
}
