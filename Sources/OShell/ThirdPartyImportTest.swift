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
                    else { children.compactMap { $0 as? NSButton }.first { $0.title == "导入" }?.performClick(nil) }
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
        } catch { checks["unexpectedError"] = false; print(error.localizedDescription) }
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_EXTERNAL_IMPORT_OUTPUT"] { try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        print(result); workspace.shutdown(); NSApp.terminate(nil)
    }
}
