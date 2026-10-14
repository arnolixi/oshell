// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum SharedConflictTest {
    static func run(_ workspace: WorkspaceController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exercise(workspace) }
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func later(_ body: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { body(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func button(_ root: NSView, _ title: String) -> NSButton? { descendants(root).compactMap { $0 as? NSButton }.first { $0.title == title } }
        func publish(_ mutate: (inout Configuration) -> Void) throws {
            let other = ConfigurationStore(directory: workspace.store.url.deletingLastPathComponent())
            var value = try other.load(); mutate(&value); try other.save(value)
        }
        do {
            let a = SessionProfile(name: "冲突会话", host: "a.example.test"), b = SessionProfile(name: "另一会话", host: "b.example.test")
            var base = workspace.configuration; base.profiles = [a, b]; base.preferences.metal = false
            checks["fixtureSaved"] = workspace.saveConfiguration(base)
            workspace.newLocal(); let pane = workspace.selectedTab!.activePane, pid = pane.terminal.process.shellPid
            var local = workspace.configuration; local.profiles[0].username = "local-user"
            try publish { $0.profiles[0].host = "remote.example.test"; $0.profiles[1].port = 2222 }
            later { root in
                let view = descendants(root).compactMap { $0 as? SharedConflictView }.first!
                checks["onlyConflictingSessionListed"] = view.table.numberOfRows == 1
                checks["explicitChoiceRequired"] = button(root, "确认保存")?.isEnabled == false
                checks["twoVersionsVisible"] = descendants(view).compactMap { $0 as? NSTextView }.contains { $0.string.contains("remote.example.test") }
                button(root, "保留本机版本")?.performClick(nil)
                checks["choiceEnablesSave"] = button(root, "确认保存")?.isEnabled == true
                button(root, "确认保存")?.performClick(nil)
            }
            checks["localChoiceSaves"] = workspace.saveConfiguration(local)
            checks["localWholeSessionPreserved"] = workspace.configuration.profiles.first { $0.id == a.id }?.username == "local-user" && workspace.configuration.profiles.first { $0.id == a.id }?.host == a.host
            checks["independentRemoteEditMerged"] = workspace.configuration.profiles.first { $0.id == b.id }?.port == 2222
            checks["resolvedDraftRemoved"] = !SharedConflictDrafts.exists(for: workspace.store)
            local = workspace.configuration; local.profiles[1].username = "pending-local"
            try publish { $0.profiles[1].host = "pending-remote.example.test" }
            later { root in button(root, "稍后处理")?.performClick(nil) }
            checks["laterDoesNotSave"] = !workspace.saveConfiguration(local)
            checks["laterRetainsDraft"] = try SharedConflictDrafts.load(for: workspace.store)?.local.profiles.first { $0.id == b.id }?.username == "pending-local"
            checks["draftOwnerOnlyPermissions"] = (try FileManager.default.attributesOfItem(atPath: SharedConflictDrafts.file(for: workspace.store).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            let revision = workspace.configurationRevision
            workspace.windowCoordinator?.reloadSharedConfiguration(interactive: false)
            checks["reloadDoesNotDiscardPendingDraft"] = workspace.configurationRevision == revision
            later { root in button(root, "保留共享版本")?.performClick(nil); button(root, "确认保存")?.performClick(nil) }
            workspace.resolvePendingSharedConflicts()
            checks["remoteChoiceSaves"] = workspace.configuration.profiles.first { $0.id == b.id }?.host == "pending-remote.example.test" && !SharedConflictDrafts.exists(for: workspace.store)
            local = workspace.configuration; local.profiles[0].host = "local-later.example.test"
            try publish { $0.profiles[0].username = "remote-later" }
            later { root in
                button(root, "保留本机版本")?.performClick(nil)
                try? publish { $0.profiles[0].port = 2200 }
                later { _ in if let modal = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: modal) } }
                button(root, "确认保存")?.performClick(nil)
            }
            checks["changedAgainStopsSave"] = !workspace.saveConfiguration(local)
            checks["changedAgainKeepsNewestRemote"] = try workspace.store.sharedSnapshot().configuration.profiles.first { $0.id == a.id }?.port == 2200
            checks["changedAgainKeepsDraft"] = SharedConflictDrafts.exists(for: workspace.store)
            later { root in button(root, "保留共享版本")?.performClick(nil); button(root, "确认保存")?.performClick(nil) }
            workspace.resolvePendingSharedConflicts()
            local = workspace.configuration; local.profiles.removeAll { $0.id == a.id }
            try publish { $0.profiles[0].name = "remote-renamed" }
            later { root in
                checks["deleteVersusEditExplained"] = descendants(root).compactMap { $0 as? NSTextView }.contains { $0.string.contains("已删除该会话") }
                button(root, "保留本机版本")?.performClick(nil); button(root, "确认保存")?.performClick(nil)
            }
            checks["deleteChoiceSaves"] = workspace.saveConfiguration(local) && !workspace.configuration.profiles.contains { $0.id == a.id }
            checks["liveTerminalNotRestarted"] = !pane.isShutdown && pane.terminal.process.shellPid == pid
            checks["savedStateMatchesDisk"] = try workspace.store.load().profiles == workspace.configuration.profiles
        } catch { checks["unexpectedFailure"] = false; print("Conflict test failed: \(error.localizedDescription)") }
        if let path = ProcessInfo.processInfo.environment["OSHELL_CONFLICT_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print("Conflict checks: \(checks.count); failures: \(checks.filter { !$0.value }.keys.sorted())")
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
