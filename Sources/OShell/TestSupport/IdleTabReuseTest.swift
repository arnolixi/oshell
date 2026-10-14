// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Real local PTYs and loopback SSH failures; no saved credentials are used.
enum IdleTabReuseTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool](), finished = false
        func finish() {
            guard !finished else { return }; finished = true
            if let path = ProcessInfo.processInfo.environment["OSHELL_IDLE_TAB_OUTPUT"] {
                let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            }
            workspace.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ name: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(12)
            func poll() {
                guard !finished else { return }
                if condition() { checks[name] = true; next() }
                else if Date() > deadline { checks[name] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
            }
            poll()
        }
        func text(_ pane: TerminalPane) -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func status(_ tab: TerminalTab) -> TabStripView.ConnectionStatus? {
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            return workspace.window?.contentView.flatMap { root in
                views(root).compactMap { $0 as? TabStripView.Item }.first { $0.id == tab.id }?.connectionStatus
            }
        }
        func stop(_ pane: TerminalPane) { pane.sendManaged(Array("exit\r".utf8)) }
        func visible(_ pane: TerminalPane) -> Bool {
            workspace.window?.contentView?.layoutSubtreeIfNeeded()
            return pane.view.window === workspace.window && pane.terminal.bounds.width > 150 && pane.terminal.bounds.height > 100
        }
        func batchAndExternal() {
            workspace.newBlankTab(); let blank = workspace.selectedTab!, old = blank.activePane
            let profiles = (1...3).map { SessionProfile(name: "batch-\($0)", kind: .local) }
            workspace.configuration.profiles = profiles
            let manager = SessionManager(workspace: workspace); manager.show(); manager.reveal(profiles[0])
            func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
            let all = views(manager.window!.contentView!)
            let table = all.compactMap { $0 as? NSTableView }.first!
            table.selectAll(nil)
            let connect = all.compactMap { $0 as? NSButton }.first { $0.title == "连接（3）" }
            checks["managerBatchActionAvailable"] = connect != nil
            let count = workspace.tabs.count
            connect?.performClick(nil)
            checks["batchReusesOnlyFirstSlot"] = old.isShutdown && blank.activePane.profile.id == profiles[0].id && workspace.tabs.count == count + 2
            checks["batchKeepsAllRequestedProfiles"] = Set(workspace.tabs.suffix(3).map { $0.activePane.profile.id }) == Set(profiles.map(\.id))
            manager.close()
            workspace.newBlankTab(); let external = workspace.selectedTab!, empty = external.activePane
            do {
                let request = try ZOCLaunchRequest.parse(["/SSH:127.0.0.1:1", "/SSHUSER:fixture", "/EMU:VT100"])
                let before = workspace.tabs.count
                workspace.openExternal(request)
                checks["externalLaunchReusesSelectedTab"] = workspace.selectedTab === external && workspace.tabs.count == before && empty.isShutdown
                checks["externalConnectionOptionsPreserved"] = external.activePane.sshConnectionGroup?.isExternal == true && external.activePane.externalTerminalType == "vt100"
                // Loopback refusal may already have terminated the PTY here.
                // It must never be displayed as authenticated in either case.
                checks["unauthenticatedStatusNotConnected"] = status(external) != nil && status(external) != .connected
                checks["tabStatusTracksConnectionState"] = status(external) == external.activePane.tabConnectionStatus
                workspace.duplicateTab(external)
                checks["connectingDoubleClickIgnored"] = workspace.tabs.count == before && workspace.selectedTab === external
                let failed = external.activePane
                wait("sshFailureReturnsToPrompt", { failed.ended && text(failed).contains("OShell >") }) {
                    let count = workspace.tabs.count
                    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
                    let item = workspace.window?.contentView.flatMap { root in
                        views(root).compactMap { $0 as? TabStripView.Item }.first { $0.id == external.id }
                    }
                    if let item, let window = workspace.window {
                        let point = item.selectButton.convert(NSPoint(x: 10, y: 10), to: nil)
                        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
                        item.selectButton.mouseDown(with: event)
                    }
                    checks["doubleClickDisconnectedTitleIgnored"] = item != nil && workspace.tabs.count == count && workspace.selectedTab === external
                    checks["doubleClickPreservesDisconnectedSource"] = !failed.isShutdown && external.activePane === failed
                    checks["disconnectedStatusShown"] = status(external) == .disconnected
                    workspace.select(external)
                    workspace.newLocal()
                    checks["failedSSHCanBeReused"] = workspace.selectedTab === external && failed.isShutdown && external.activePane.profile.kind == .local
                    checks["reusedSSHPaneVisible"] = visible(external.activePane)
                    finish()
                }
            } catch { checks["externalFixtureValid"] = false; finish() }
        }
        func toolAndBlank() {
            workspace.newBlankTab(); let toolTab = workspace.selectedTab!, tool = toolTab.activePane
            tool.sendManaged(Array("ping 127.0.0.1\r".utf8))
            wait("localToolRunning", { tool.isRunningLocalTool }) {
                let count = workspace.tabs.count
                workspace.newLocal()
                checks["runningToolIsNotReplaced"] = workspace.tabs.count == count + 1 && workspace.selectedTab !== toolTab && !tool.isShutdown && tool.isRunningLocalTool
                // Blank tabs do not represent an established connection.
                workspace.newBlankTab(); let empty = workspace.selectedTab!
                let total = workspace.tabs.count
                workspace.duplicateTab(empty)
                checks["blankDoubleClickIgnored"] = workspace.selectedTab === empty && workspace.tabs.count == total && !empty.activePane.isShutdown
                checks["blankStatusDisconnected"] = status(empty) == .disconnected
                workspace.select(empty); let old = empty.activePane, before = workspace.tabs.count
                workspace.newLocal()
                checks["blankCanBeReused"] = workspace.selectedTab === empty && workspace.tabs.count == before && old.isShutdown && !empty.activePane.isBlank
                batchAndExternal()
            }
        }
        func splitAndGroup() {
            workspace.splitVertical()
            let tab = workspace.selectedTab!, old = tab.activePane
            let peer = tab.layout.panes.first { $0 !== old }!
            let peerPID = peer.terminal.process.shellPid
            do {
                let group = try workspace.createTabGroup(name: "Reuse", activate: false)
                checks["moveToNamedGroup"] = workspace.moveTab(tab.id, toGroup: group.id)
            } catch { checks["moveToNamedGroup"] = false }
            workspace.select(tab); workspace.togglePaneZoom()
            let groupID = workspace.activeTabGroupID, numbers = workspace.tabNumbers, count = workspace.tabs.count
            stop(old)
            wait("selectedSplitExited", { old.ended }) {
                workspace.newLocal()
                checks["splitReusesOnlySelectedLeaf"] = workspace.selectedTab === tab && workspace.tabs.count == count && tab.layout.panes.count == 2 && old.isShutdown
                checks["liveSiblingPreserved"] = tab.layout.panes.contains { $0 === peer } && !peer.isShutdown && peer.terminal.process.shellPid == peerPID
                checks["groupAndNumberPreserved"] = workspace.activeTabGroupID == groupID && workspace.tabNumbers == numbers
                checks["zoomPreserved"] = tab.zoomedPane === tab.activePane && visible(tab.activePane)
                workspace.togglePaneZoom()
                wait("splitLayoutVisibleAfterRestore", { visible(peer) && visible(tab.activePane) }) {
                    stop(peer)
                    wait("unselectedSplitExited", { peer.ended }) {
                        let selected = tab.activePane
                        workspace.newLocal()
                        checks["idleSiblingNotStolen"] = workspace.selectedTab !== tab && !peer.isShutdown && !selected.isShutdown && workspace.tabs.count == count + 1
                        toolAndBlank()
                    }
                }
            }
        }
        workspace.configuration.preferences.metal = false
        workspace.newLocal(); let first = workspace.selectedTab!, old = first.activePane
        checks["localConnectionStatusShown"] = status(first) == .connected && old.canDuplicateConnection
        workspace.newLocal(); let other = workspace.selectedTab!
        checks["liveSessionOpensNewTab"] = workspace.tabs.count == 2 && first !== other && !old.isShutdown
        stop(old)
        wait("shellExitRetainsPrompt", { old.ended && text(old).contains("OShell >") }) {
            workspace.newLocal()
            checks["backgroundIdleTabNotStolen"] = workspace.tabs.count == 3 && !old.isShutdown
            workspace.select(first)
            let count = workspace.tabs.count, ids = workspace.tabs.map(\.id)
            workspace.newLocal()
            checks["selectedExitedTabReused"] = workspace.selectedTab === first && workspace.tabs.count == count && workspace.tabs.map(\.id) == ids
            checks["oldPaneResourcesReleased"] = old.isShutdown && old.terminal.owner == nil && old.sshConnectionGroup == nil
            checks["replacementReceivesFocus"] = workspace.window?.firstResponder === first.activePane.terminal
            wait("replacementShellAcceptsInput", {
                first.activePane.sendManaged(Array("printf 'REUSED_PTY_OK\\n'\r".utf8))
                return text(first.activePane).contains("REUSED_PTY_OK")
            }) { splitAndGroup() }
        }
    }
}
