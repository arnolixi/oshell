// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Isolated AppKit regression: closing a leaf must not terminate its siblings.
enum PaneCloseTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window else { return }
        var checks = [String: Bool]()
        var buttonGeometry = [String]()
        func later(_ action: @escaping () -> Void) {
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in action() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func finish() {
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "buttonGeometry": buttonGeometry]
            if let path = ProcessInfo.processInfo.environment["OSHELL_PANE_CLOSE_OUTPUT"] {
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            }
            workspace.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ name: String, _ ready: @escaping () -> Bool, _ action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(10)
            func poll() {
                if ready() { checks[name] = true; action() }
                else if Date() > deadline { checks[name] = false; finish() }
                else { later(poll) }
            }; poll()
        }
        func answerConfirmation(_ title: String) {
            later {
                guard let root = NSApp.modalWindow?.contentView,
                      let button = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                    checks["confirmation-\(title)"] = false; NSApp.abortModal(); return
                }
                checks["confirmation-\(title)"] = true; button.performClick(nil)
            }
        }
        func blankCases() {
            for mode in [TabArrangement.tabs, .tiled] {
                workspace.arrange(mode)
                workspace.newBlankTab(); let tab = workspace.selectedTab!, a = tab.activePane
                workspace.splitVertical(); let b = tab.activePane
                workspace.splitHorizontal(); let c = tab.activePane
                window.contentView?.layoutSubtreeIfNeeded()
                let key = "\(mode.rawValue)"
                buttonGeometry += tab.layout.panes.map { "\(key): hidden=\($0.closeButton.isHidden), attached=\($0.closeButton.window === window), frame=\($0.closeButton.frame)" }
                checks["closeButtonsVisible-" + key] = tab.layout.panes.allSatisfy { !$0.closeButton.isHidden && $0.closeButton.window === window && $0.closeButton.bounds.width == 22 }
                checks["closeButtonsFitTopRight-" + key] = tab.layout.panes.allSatisfy {
                    let frame = $0.closeButton.convert($0.closeButton.bounds, to: $0.view)
                    return $0.view.bounds.contains(frame) && abs(frame.maxX - ($0.view.bounds.width - 8)) < 1 && frame.height == 22
                }
                workspace.syncTargets = Set([a.id, b.id, c.id]); workspace.composerTargets = workspace.syncTargets
                workspace.quickSendSelected = workspace.syncTargets
                a.activate(); c.closeButton.performClick(nil)
                checks["inactiveNestedLeafOnly-" + key] = c.isShutdown && !a.isShutdown && !b.isShutdown && tab.layout.panes.map(\.id) == [a.id, b.id]
                checks["inactiveClosePreservesFocus-" + key] = tab.activePane === a && window.firstResponder === a.terminal
                checks["inputTargetsPruned-" + key] = workspace.syncTargets == Set([a.id, b.id]) && workspace.composerTargets == workspace.syncTargets && !workspace.quickSendSelected.contains(c.id)
                workspace.quickSendBar.fill(.init(text: "draft", appendReturn: true))
                let editor = workspace.quickSendBar.field.currentEditor()
                b.sendManaged(Array("quit\r".utf8))
                checks["endedExitOnlyClosesLeaf-" + key] = b.isShutdown && !a.isShutdown && workspace.tabs.count == 1 && tab.layout.panes.count == 1
                checks["quickSendFocusPreserved-" + key] = editor != nil && window.firstResponder === editor
                checks["collapsedPaneFillsTab-" + key] = tab.layout.view === a.view && a.closeButton.isHidden && workspace.syncTargets.isEmpty
                a.sendManaged(Array("exit\r".utf8))
                checks["lastLeafClosesTab-" + key] = workspace.tabs.isEmpty && window.firstResponder === editor
            }
            workspace.arrange(.tabs)
            workspace.newBlankTab(); let tab = workspace.selectedTab!, a = tab.activePane
            workspace.splitVertical(); let b = tab.activePane
            workspace.splitHorizontal(); let c = tab.activePane
            b.activate(); workspace.closePane()
            checks["keyboardCloseSelectsAdjacent"] = tab.layout.panes.map(\.id) == [a.id, c.id] && tab.activePane === c && window.firstResponder === c.terminal
            workspace.newBlankTab(); let other = workspace.selectedTab!
            let item = workspace.sessionTabContextMenu(tab.id).items.first { $0.action == #selector(WorkspaceController.closePaneFromTabMenu(_:)) }
            if let item { workspace.closePaneFromTabMenu(item) }
            checks["backgroundContextClosePreservesSelectedTab"] = item != nil && c.isShutdown && tab.layout.panes.count == 1 && workspace.selectedTab === other && window.firstResponder === other.activePane.terminal
            workspace.select(tab); workspace.splitHorizontal(); let d = tab.activePane
            workspace.chooseQuickSendScope(.all)
            workspace.quickSendBar.fill(.init(text: "exit", appendReturn: true)); workspace.quickSendBar.submit()
            checks["broadcastClosesEachLeafExactlyOnce"] = workspace.tabs.isEmpty && a.isShutdown && d.isShutdown && other.activePane.isShutdown
            checks["broadcastRetainsQuickSendFocus"] = workspace.quickSendBar.field.currentEditor() != nil && window.firstResponder === workspace.quickSendBar.field.currentEditor()
            finish()
        }
        later {
            workspace.configuration.preferences.metal = false
            workspace.newLocal(); let tab = workspace.selectedTab!, a = tab.activePane
            workspace.splitVertical(); let b = tab.activePane
            wait("bothLocalProcessesStarted", { a.terminal.process.running && b.terminal.process.running && a.receivedBytes > 0 && b.receivedBytes > 0 }) {
                let pid = b.terminal.process.shellPid
                b.activate(); answerConfirmation("取消"); a.closeButton.performClick(nil)
                checks["cancelKeepsBothProcesses"] = tab.layout.panes.count == 2 && !a.isShutdown && !b.isShutdown && b.terminal.process.shellPid == pid
                answerConfirmation("关闭"); a.closeButton.performClick(nil)
                checks["liveCloseOnlyShutsTarget"] = a.isShutdown && !b.isShutdown && tab.layout.panes.count == 1 && tab.activePane === b && b.terminal.process.shellPid == pid && b.terminal.process.running
                checks["liveSiblingRetainsFocus"] = window.firstResponder === b.terminal
                let count = b.receivedBytes
                b.sendManaged(Array("printf 'pane-survivor\\n'\r".utf8))
                wait("survivingProcessStillResponds", { b.receivedBytes > count }) {
                    b.sendManaged(Array("exit\r".utf8))
                    wait("survivorEnded", { b.ended }) {
                        b.sendManaged(Array("exit\r".utf8)); blankCases()
                    }
                }
            }
        }
    }
}
