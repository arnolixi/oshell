// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum ThirdPartyImportTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oshell-import-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func descendants(_ view: NSView) -> [NSView] {
            let children = (view as? NSTabView)?.tabViewItems.compactMap(\.view) ?? view.subviews
            return [view] + children.flatMap(descendants)
        }
        func handleDialogs(cancel: Bool, label: String) -> Timer {
            var previewHandled = false
            let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
                guard let window = NSApp.modalWindow, let view = window.contentView else { return }
                let children = descendants(view)
                if let preview = children.compactMap({ $0 as? ThirdPartyImportPreview }).first, !previewHandled {
                    previewHandled = true
                    checks[label + "PreviewShowsParsedRows"] = preview.report.profiles.count == 1 && preview.table.numberOfRows == 1
                    checks[label + "PreviewHasMigrationNotes"] = preview.report.notes.contains("密码") && !preview.report.notes.contains("FIXTURE_SECRET_NOT_IMPORTED")
                    checks[label + "NoPasswordPrompt"] = !children.contains { $0 is NSSecureTextField }
                    if cancel { checks[label + "EscapeCancels"] = PopupKeyboard.dismiss(window: window) }
                    else {
                        (children.first { $0.identifier?.rawValue == "import.xshell.passwords" } as? NSButton)?.state = .off
                        children.compactMap { $0 as? NSButton }.first { $0.title == "导入" }?.performClick(nil)
                    }
                } else if children.compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.hasPrefix("已导入 ") }) {
                    _ = PopupKeyboard.dismiss(window: window)
                }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode")); return timer
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("fixture.xsh")
            try Data("[SessionInfo]\nVersion=8.0\n[CONNECTION]\nProtocol=SSH\nHost=192.0.2.80\nPort=2222\n[CONNECTION:AUTHENTICATION]\nUserName=ops\nPassword=FIXTURE_SECRET_NOT_IMPORTED\n".utf8).write(to: url)
            let parsed = try ThirdPartySessionImporter.read([url], format: .xshell)
            var existing = parsed.profiles[0]; existing.group = "迁移/Xshell"
            var initial = workspace.configuration; initial.profiles = [existing]; _ = workspace.saveConfiguration(initial)
            let revision = workspace.configurationRevision
            let cancel = handleDialogs(cancel: true, label: "cancel")
            SessionTransfer.importExternal(at: [url], format: .xshell, workspace: workspace, directory: "迁移")
            cancel.invalidate()
            checks["cancelLeavesConfigurationUnchanged"] = workspace.configurationRevision == revision && workspace.configuration.profiles == [existing]
            let accept = handleDialogs(cancel: false, label: "accept")
            SessionTransfer.importExternal(at: [url], format: .xshell, workspace: workspace, directory: "迁移")
            accept.invalidate()
            checks["acceptedImportPreservesOriginalAndRenamesCopy"] = workspace.configuration.profiles.count == 2 && workspace.configuration.profiles[0] == existing && workspace.configuration.profiles[1].name.contains("导入副本")
            checks["importDoesNotConnect"] = workspace.tabs.isEmpty
            checks["connectionFieldsPersist"] = (try workspace.store.load()).profiles.last?.host == "192.0.2.80" && workspace.configuration.profiles.last?.port == 2222
            checks["thirdPartyCiphertextNeverSaved"] = !String(decoding: try Data(contentsOf: workspace.store.url), as: UTF8.self).contains("FIXTURE_SECRET_NOT_IMPORTED")
            let links = handleDialogs(cancel: false, label: "links")
            try SessionTransfer.importExternalReport(parsed, format: .xshell, workspace: workspace, directory: "Links")
            links.invalidate()
            checks["linksImportUsesExistingReferenceRules"] = workspace.configuration.sessionLinks.entries.count == 1 && workspace.configuration.sessionLinks.entries[0].folder == "Xshell"
            // Use known synthetic credentials; no real password is put into test output.
            let cipher = "Rrm3P3AL0iDV7nBbS2bHvh7ZAvuN1NSJl8ZFL11+UJ+82+KAixa89O3OTAfRTg=="
            try Data("[SessionInfo]\nVersion=8.1\n[CONNECTION]\nProtocol=SSH\nHost=192.0.2.80\nPort=2222\n[CONNECTION:AUTHENTICATION]\nUserName=ops\nPassword=\(cipher)\n".utf8).write(to: url)
            func importPassword(_ master: String?, label: String) {
                var previewHandled = false, masterHandled = false
                let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
                    guard let window = NSApp.modalWindow, let root = window.contentView else { return }
                    let children = descendants(root)
                    if let preview = children.compactMap({ $0 as? ThirdPartyImportPreview }).first, !previewHandled {
                        previewHandled = true
                        checks[label + "DetectedPassword"] = preview.report.passwordCount == 1
                        (children.first { $0.identifier?.rawValue == "import.xshell.passwords" } as? NSButton)?.state = .on
                        (children.first { $0.identifier?.rawValue == "import.xshell.fillMissing" } as? NSButton)?.state = .on
                        children.compactMap { $0 as? NSButton }.first { $0.title == "导入" }?.performClick(nil)
                    } else if let input = children.first(where: { $0.identifier?.rawValue == "import.xshell.master" }) as? NSSecureTextField, !masterHandled {
                        masterHandled = true
                        if let master { input.stringValue = master; children.compactMap { $0 as? NSButton }.first { $0.title == "确定" }?.performClick(nil) }
                        else { _ = PopupKeyboard.dismiss(window: window) }
                    } else if children.compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.hasPrefix("已补充 ") || $0.stringValue.hasPrefix("导入失败") }) {
                        _ = PopupKeyboard.dismiss(window: window)
                    }
                }
                RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode"))
                SessionTransfer.importExternal(at: [url], format: .xshell, workspace: workspace, directory: "迁移")
                timer.invalidate()
            }
            let beforePasswords = workspace.configuration, passwordRevision = workspace.configurationRevision
            importPassword(nil, label: "cancelMaster")
            checks["cancelMasterDoesNotSave"] = workspace.configurationRevision == passwordRevision
            importPassword("wrong-fixture-master", label: "wrongMaster")
            checks["wrongMasterDoesNotSave"] = workspace.configurationRevision == passwordRevision && workspace.configuration.profiles == beforePasswords.profiles
            importPassword("123123", label: "correctMaster")
            checks["supplementDoesNotCreateDuplicateSessions"] = workspace.configuration.profiles.map(\.id) == beforePasswords.profiles.map(\.id)
            if let profile = workspace.configuration.profiles.first(where: { $0.id == existing.id }), let saved = profile.encryptedPassword {
                checks["supplementEncryptedForOShell"] = saved.localKeyID != nil && saved.ciphertext != cipher
                checks["importedPasswordWorks"] = try PasswordVault.shared.readSavedPassword(profile) == "This is a test"
                let stored = String(decoding: try Data(contentsOf: workspace.store.url), as: UTF8.self)
                checks["noPlaintextOrVendorCipherOnDisk"] = !stored.contains("This is a test") && !stored.contains(cipher)
            } else { checks["supplementEncryptedForOShell"] = false }
            let alreadySaved = workspace.configurationRevision
            importPassword("123123", label: "repeat")
            checks["existingPasswordPreserved"] = workspace.configurationRevision == alreadySaved
            if let path = ProcessInfo.processInfo.environment["OSHELL_IMPORT_INSPECT_XTS"] {
                let real = try ThirdPartySessionImporter.read([URL(fileURLWithPath: path)], format: .xshell)
                print("Local XTS inspection: \(real.profiles.count) sessions, \(real.passwordCount) encrypted password records, \(real.skippedCount) skipped. No connection details printed.")
                checks["localXTSContainsPasswords"] = real.passwordCount > 0
            }
        } catch { checks["unexpectedError"] = false; print(error.localizedDescription) }
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_EXTERNAL_IMPORT_OUTPUT"] { try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        print(result); workspace.shutdown(); NSApp.terminate(nil)
    }
}
