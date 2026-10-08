// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum MultiWindowTest {
    static func run(_ first: WorkspaceController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exercise(first) }
    }
    private static func exercise(_ first: WorkspaceController) {
        guard let windows = first.windowCoordinator else { fatalError("Missing window coordinator") }
        var checks = [String: Bool]()
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        func action(_ selector: Selector) -> NSMenuItem { items(NSApp.mainMenu!).first { $0.action == selector }! }
        func respond(_ title: String) {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                if let root = NSApp.modalWindow?.contentView,
                   let button = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) { button.performClick(nil) }
                else { NSApp.abortModal() }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        first.newLocal()
        let original = first.selectedTab!, pane = original.activePane
        var second: WorkspaceController? = windows.newWindow()
        weak var weakSecond = second
        checks["newWindowStartsEmpty"] = second!.tabs.isEmpty && first.tabs.count == 1
        checks["sharedUpdater"] = first.appUpdater === second!.appUpdater
        checks["newWindowShortcut"] = ShortcutRuntime.current.action(for: .init(45, KeyboardShortcut.command | KeyboardShortcut.shift)) == .newWindow
        let blank = action(#selector(WorkspaceController.newBlankTab))
        checks["menuTargetsActiveWindow"] = blank.target as? WorkspaceController === second
        _ = NSApp.sendAction(blank.action!, to: blank.target, from: blank)
        checks["menuCreatesOnlyInActiveWindow"] = second!.tabs.count == 1 && first.tabs.count == 1
        first.show(); windows.activate(first)
        checks["menuFollowsWindowSwitch"] = blank.target as? WorkspaceController === first
        var value = first.configuration
        let profile = SessionProfile(name: "Multiwindow fixture", host: "example.invalid")
        value.profiles.append(profile)
        checks["saveSharedSession"] = first.saveConfiguration(value) && second!.configuration.profiles.contains(where: { $0.id == profile.id })
        var other = second!.configuration; other.preferences.fontSize = 16
        checks["saveFromSecondPreservesFirstEdit"] = second!.saveConfiguration(other) && first.configuration.preferences.fontSize == 16 && (try? first.store.load().profiles.contains { $0.id == profile.id }) == true
        first.quickSendScope = .all; second!.quickSendScope = .all
        checks["broadcastWindowIsolation"] = first.quickSendCandidates.map(\.id) == [pane.id] && !second!.quickSendCandidates.contains(where: { $0 === pane })
        first.syncTargets = [pane.id]; first.composerTargets = [pane.id]
        let pid = pane.terminal.process.shellPid
        first.move(original, to: second!)
        checks["movePreservesTerminalAndProcess"] = second!.tabs.contains(where: { $0 === original }) && pid > 0 && pane.terminal.process.shellPid == pid && !pane.isShutdown
        checks["sourceRemovesMovedTargets"] = first.tabs.isEmpty && first.syncTargets.isEmpty && first.composerTargets.isEmpty && first.quickSendCandidates.isEmpty
        checks["movedViewBelongsToDestination"] = pane.view.window === second!.window
        pane.onFocus?(pane)
        checks["movedFocusCallbackRebound"] = second!.selectedTab === original
        first.newLocal(); let survivingPane = first.selectedTab!.activePane
        respond("取消")
        checks["cancelQuitLeavesAllSessions"] = !windows.canQuit() && !pane.isShutdown && !survivingPane.isShutdown
        second!.show()
        respond("取消"); second!.window?.performClose(nil)
        checks["cancelWindowCloseLeavesSessions"] = second!.window?.isVisible == true && !pane.isShutdown && windows.workspaces.count == 2
        respond("关闭窗口"); second!.window?.performClose(nil)
        checks["closeOnlyStopsItsSessions"] = pane.isShutdown && !survivingPane.isShutdown && windows.workspaces.count == 1
        second = nil
        // Let the native close event and autoreleased responder objects drain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            checks["closedControllerReleased"] = weakSecond == nil
            checks["externalLaunchFollowsRemainingWindow"] = windows.externalWorkspace() === first
            first.shutdown(); first.window?.close()
            checks["lastWindowCanCloseWithoutQuitting"] = windows.workspaces.isEmpty
            let reopened = windows.newWindow()
            checks["newWindowAfterLastClosed"] = reopened.isSecurityUnlocked && reopened.window?.isVisible == true
            let reopenedBlank = action(#selector(WorkspaceController.newBlankTab))
            checks["menuRetargetsAfterAllWindowsClosed"] = reopenedBlank.target as? WorkspaceController === reopened
            _ = NSApp.sendAction(reopenedBlank.action!, to: reopenedBlank.target, from: reopenedBlank)
            checks["reopenedWindowMenuWorks"] = reopened.tabs.count == 1
            checks["savedConfigurationSurvivesReopen"] = reopened.configuration.profiles.contains(where: { $0.id == profile.id }) && reopened.configuration.preferences.fontSize == 16
            checks["singleSharedUpdaterAfterReopen"] = reopened.appUpdater === windows.updater
            if let output = ProcessInfo.processInfo.environment["OSHELL_MULTI_WINDOW_OUTPUT"] {
                try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            }
            print("Multiwindow checks: \(checks.count); failures: \(checks.filter { !$0.value }.keys.sorted())")
            reopened.shutdown(); NSApp.terminate(nil)
        }
    }
}
