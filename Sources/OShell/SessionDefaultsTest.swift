// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum SessionDefaultsTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] {
            let children = (view as? NSTabView)?.tabViewItems.compactMap(\.view) ?? view.subviews
            return [view] + children.flatMap(descendants)
        }
        func input(_ root: NSView, _ id: String) -> NSTextField? { descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id } }
        func dismissNext() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } } }
        func pressNext(_ title: String) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if let root = NSApp.modalWindow?.contentView { descendants(root).compactMap { $0 as? NSButton }.first { $0.title == title }?.performClick(nil) } } }
        var source = SessionProfile(name: "生产主机", group: "生产/华东", host: "192.0.2.1", username: "ops")
        source.keepAlive.interval = 61; source.legacySSH = true
        var rule = TunnelRule(); rule.listenPort = 9090; source.tunnels = [rule]
        var file = SessionProfile(name: "文件", group: "生产/华东", kind: .ftp, host: "192.0.2.2", port: 21, username: "ftp")
        file.initialDirectory = "/upload"
        var config = controller.configuration; config.profiles = [source, file]; config.directories = [source.group]
        checks["fixtureSaved"] = controller.saveConfiguration(config)
        let manager = SessionManager(workspace: controller); manager.reveal(source)
        let table = descendants(manager.window!.contentView!).compactMap { $0 as? NSTableView }.first!
        let menu = manager.contextMenu(for: table.selectedRow)
        checks["defaultsAvailableInContext"] = menu.items.contains { $0.title == "会话默认属性…" }
        let copy = menu.items.first { $0.title == "复制会话" }!
        _ = NSApp.sendAction(copy.action!, to: copy.target, from: copy)
        let duplicated = manager.selectedProfile!
        checks["copyActionSelectsIndependentProfile"] = duplicated.id != source.id && duplicated.name == source.name + " - 副本" && duplicated.group == source.group
        checks["copyPreservesConnectionOptions"] = duplicated.host == source.host && duplicated.keepAlive == source.keepAlive && duplicated.tunnels[0].listenPort == 9090 && duplicated.legacySSH
        checks["sourceUnchanged"] = controller.configuration.profiles.first { $0.id == source.id } == source
        let another = controller.duplicateSavedSession(source.id)
        checks["copyNamesAreUnique"] = another?.name == source.name + " - 副本 2"
        manager.reveal(file)
        let fileAction = manager.contextMenu(for: table.selectedRow).items.first { $0.title == "复制会话" }!
        _ = NSApp.sendAction(fileAction.action!, to: fileAction.target, from: fileAction)
        checks["fileCopyPreservesProtocol"] = manager.selectedProfile?.kind == .ftp && manager.selectedProfile?.initialDirectory == "/upload"
        checks["parentHasNoCopyAction"] = !manager.contextMenu(for: 0).items.contains { $0.title == "复制会话" }
        checks["blankHasNoCopyAction"] = !manager.contextMenu(for: -1).items.contains { $0.title == "复制会话" }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let root = NSApp.modalWindow?.contentView else { return }
            input(root, "defaults.sshPort")?.stringValue = "2222"
            input(root, "defaults.aliveInterval")?.stringValue = "75"
            descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "保存默认值" }?.performClick(nil)
        }
        controller.showSessionDefaults()
        checks["realDefaultDialogSaves"] = controller.configuration.sessionDefaults.sshPort == 2222 && controller.configuration.sessionDefaults.keepAlive.interval == 75
        checks["defaultsDoNotChangeExistingProfiles"] = controller.configuration.profiles.first { $0.id == source.id }?.keepAlive.interval == 61
        checks["defaultsPersistAfterReload"] = (try? controller.store.load().sessionDefaults) == controller.configuration.sessionDefaults
        let revision = controller.configurationRevision; dismissNext(); controller.showSessionDefaults()
        checks["escapeCancelsDefaults"] = controller.configurationRevision == revision
        let invalid = SessionDefaultsEditor(controller.configuration.sessionDefaults); invalid.interval.stringValue = "0"
        checks["invalidKeepAliveRejected"] = (try? invalid.values()) == nil
        let defaults = controller.configuration.sessionDefaults
        let editor = SessionEditor(nil, profiles: [], directories: [], initialDirectory: "生产", defaults: defaults)
        let root = editor.dialog.accessoryView!
        checks["newEditorShowsAbsoluteDirectory"] = input(root, "session.directory")?.stringValue == "/生产"
        let directoryChoices = descendants(root).compactMap { $0 as? NSComboBox }.first { $0.identifier?.rawValue == "session.directory" }
        checks["directoryChoicesIncludeRoot"] = directoryChoices?.objectValues.first as? String == "/"
        checks["newEditorUsesDefaultPort"] = input(root, "session.port")?.stringValue == "2222"
        checks["newEditorUsesDefaultKeepAlive"] = input(root, "session.keepAlive.interval")?.stringValue == "75"
        input(root, "session.host")?.stringValue = "192.0.2.99"
        pressNext("保存"); let created = editor.run()
        checks["newSessionSavesDefaults"] = created?.keepAlive.interval == 75 && created?.port == 2222
        let existing = SessionEditor(source, profiles: [], directories: [], initialDirectory: "", defaults: defaults)
        let oldRoot = existing.dialog.accessoryView!
        checks["oldDirectoryDisplaysLinuxPath"] = input(oldRoot, "session.directory")?.stringValue == "/生产/华东"
        input(oldRoot, "session.directory")?.stringValue = "../华北//数据库/./"
        checks["editingKeepsOriginalValues"] = input(oldRoot, "session.keepAlive.interval")?.stringValue == "61"
        existing.useDefaultKeepAlive()
        checks["applyGlobalKeepAliveDoesNotChangePort"] = input(oldRoot, "session.keepAlive.interval")?.stringValue == "75" && input(oldRoot, "session.port")?.stringValue == "22"
        pressNext("保存"); let edited = existing.run()
        checks["appliedKeepAlivePersistsInEditor"] = edited?.keepAlive.interval == 75
        checks["relativeDirectoryResolvesBeforeSave"] = edited?.group == "生产/华北/数据库"
        checks["directoryEditPreservesConnectionAndRemotePath"] = edited?.id == source.id && edited?.host == source.host && edited?.initialDirectory == source.initialDirectory
        let rootEditor = SessionEditor(source, profiles: [], directories: ["生产", "生产/华东"], initialDirectory: "")
        input(rootEditor.dialog.accessoryView!, "session.directory")?.stringValue = "/"
        pressNext("保存"); checks["rootPathSavesAsRoot"] = rootEditor.run()?.group == ""

        let switched = SessionEditor(nil, profiles: [], directories: [], initialDirectory: "", defaults: defaults)
        switched.protocolKind.selectItem(at: 2); switched.protocolChanged()
        checks["newProtocolSwitchUsesFTPDefaults"] = input(switched.dialog.accessoryView!, "session.port")?.stringValue == "21" && input(switched.dialog.accessoryView!, "session.user")?.stringValue == "anonymous"

        do {
            let master = "copy-test-master"
            var secure = source; secure.id = UUID(); secure.name = "加密源"
            secure.encryptedPassword = try SessionCipher.encrypt("copy-secret", master: master, profile: secure, identity: SSHIdentity(host: secure.host, user: secure.username, port: secure.port))
            PasswordVault.shared.unlockForTesting(master)
            var value = controller.configuration; value.profiles.append(secure); _ = controller.saveConfiguration(value)
            PasswordVault.shared.lock(); let before = controller.configurationRevision
            dismissNext(); checks["unlockCancelCreatesNoCopy"] = controller.duplicateSavedSession(secure.id) == nil && controller.configurationRevision == before
            PasswordVault.shared.unlockForTesting(master)
            if let secureCopy = controller.duplicateSavedSession(secure.id), let envelope = secureCopy.encryptedPassword {
                checks["realCopyRebindsSavedPassword"] = try SessionCipher.decrypt(envelope, master: master, profile: secureCopy) == "copy-secret"
                checks["encryptedCopySavedToDisk"] = try controller.store.load().profiles.contains { $0.id == secureCopy.id }
            } else { checks["realCopyRebindsSavedPassword"] = false }
        } catch { checks["encryptedCopySetup"] = false }
        checks["noNetworkSessionsOpened"] = controller.tabs.isEmpty
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_SESSION_DEFAULTS_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print(report); manager.close(); controller.shutdown(); NSApp.terminate(nil)
    }
}
