// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum EndedBroadcastTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool](), finished = false
        func text(_ pane: TerminalPane) -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func finish() {
            guard !finished else { return }; finished = true
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            let path = ProcessInfo.processInfo.environment["OSHELL_ENDED_BROADCAST_OUTPUT"] ?? "/tmp/oshell-ended-broadcast.json"
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            print(report); controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(12)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; action() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() } }
            }; poll()
        }
        func pair() -> [TerminalPane] {
            controller.newLocal(); let first = controller.selectedTab!.activePane
            controller.newLocal(); return [first, controller.selectedTab!.activePane]
        }
        func exitProcesses(_ panes: [TerminalPane]) { panes.forEach { $0.terminal.process.send(data: Array("exit\r".utf8)[...]) } }
        let first = pair(); controller.syncTargets = Set(first.map(\.id)); controller.refreshOperatorState()
        first[0].terminal.insertText("exit\r", replacementRange: NSRange(location: 0, length: 0))
        wait("synchronizedShellExitRetainsTabs", { first.allSatisfy(\.ended) }) {
            checks["disconnectDoesNotStopSync"] = controller.syncTargets == Set(first.map(\.id)) && controller.tabs.count == 2
            checks["endedTabsRemainInputTargets"] = first.allSatisfy(\.acceptsManagedInput)
            controller.chooseQuickSendScope(.all)
            checks["allScopeIncludesEndedTabs"] = Set(controller.quickSendTargets.map(\.id)) == Set(first.map(\.id))
            checks["scopeShowsDisconnectedTargets"] = controller.quickSendBar.scopeButton.toolTip?.contains("已断开（本地输入）") == true
            checks["quickSendToAllEndedSucceeds"] = controller.sendQuickCommand(.init(text: "help", appendReturn: true))
            checks["endedCommandsStayLocal"] = controller.tabs.count == 2 && first.allSatisfy { text($0).contains("OShell > help") && !$0.terminal.process.running }
            first[0].terminal.insertText("qu", replacementRange: NSRange(location: 0, length: 0))
            checks["typingFromEndedSourceBroadcasts"] = first.allSatisfy { text($0).contains("OShell > qu") }
            first[0].terminal.insertText("it\r", replacementRange: NSRange(location: 0, length: 0))
            checks["typedQuitClosesAllEndedTabs"] = controller.tabs.isEmpty && first.allSatisfy(\.isShutdown)

            let quick = pair(); exitProcesses(quick)
            wait("quickTargetsEnded", { quick.allSatisfy(\.ended) }) {
                controller.chooseQuickSendScope(.all)
                controller.quickSendBar.fill(.init(text: "exit", appendReturn: true)); controller.quickSendBar.submit()
                checks["quickBarExitClosesAll"] = controller.tabs.isEmpty && controller.quickSendBar.field.stringValue.isEmpty

                let composed = pair(); exitProcesses(composed)
                wait("composerTargetsEnded", { composed.allSatisfy(\.ended) }) {
                    controller.composerTargets = Set(composed.map(\.id)); controller.sendComposed("quit", appendReturn: true)
                    checks["composerQuitClosesAll"] = controller.tabs.isEmpty

                    let pasted = pair(); exitProcesses(pasted)
                    wait("pasteTargetsEnded", { pasted.allSatisfy(\.ended) }) {
                        controller.syncTargets = Set(pasted.map(\.id)); controller.refreshOperatorState()
                        controller.configuration.preferences.confirmMultilinePaste = false
                        controller.pasteText("quit\n", from: pasted[0])
                        checks["pasteFromEndedSourceClosesAll"] = controller.tabs.isEmpty

                        let mixed = pair(); exitProcesses([mixed[0]])
                        wait("mixedConnectionState", { mixed[0].ended && !mixed[1].ended }) {
                            controller.chooseQuickSendScope(.all)
                            _ = controller.sendQuickCommand(.init(text: "printf 'MIXED_LIVE_MARKER\\n'", appendReturn: true))
                            wait("livePeerExecutesCommand", { text(mixed[1]).contains("\nMIXED_LIVE_MARKER\n") }) {
                                checks["endedPeerDoesNotExecuteRemoteCommand"] = !text(mixed[0]).contains("\nMIXED_LIVE_MARKER\n") && !mixed[0].terminal.process.running && controller.tabs.count == 2
                                let endedTab = controller.tabs.first { $0.layout.panes.contains { $0 === mixed[0] } }!
                                controller.quickSendScope = .selected; controller.quickSendSelected = [mixed[0].id]
                                _ = controller.sendQuickCommand(.init(text: "exit", appendReturn: true))
                                checks["selectedEndedClosePreservesLivePeer"] = !controller.tabs.contains { $0 === endedTab } && controller.tabs.count == 1 && mixed[1].terminal.process.running
                                exitProcesses([mixed[1]])
                                wait("lastPeerEnded", { mixed[1].ended }) {
                                    _ = controller.sendQuickCommandForTestAll("quit")
                                    controller.newLocal(); controller.splitVertical()
                                    let split = controller.selectedTab!, children = split.layout.panes
                                    exitProcesses([children[0]])
                                    wait("mixedSplitState", { children[0].ended && !children[1].ended }) {
                                        controller.quickSendScope = .selected; controller.quickSendSelected = [children[0].id]
                                        let cancel = Timer(timeInterval: 0.05, repeats: true) { timer in
                                            if let window = NSApp.modalWindow { timer.invalidate(); _ = PopupKeyboard.dismiss(window: window) }
                                        }
                                        RunLoop.main.add(cancel, forMode: .modalPanel)
                                        _ = controller.sendQuickCommand(.init(text: "quit", appendReturn: true))
                                        cancel.invalidate()
                                        checks["mixedSplitStillRequiresCloseConfirmation"] = controller.tabs.contains { $0 === split } && !children[0].isShutdown && children[1].terminal.process.running
                                        exitProcesses([children[1]])
                                        wait("splitTargetsEnded", { children.allSatisfy(\.ended) }) {
                                            controller.chooseQuickSendScope(.all)
                                            checks["splitExitBatchCompletes"] = controller.sendQuickCommand(.init(text: "quit", appendReturn: true)) && controller.tabs.isEmpty
                                            checks["closedPanesRejectFurtherInput"] = children.allSatisfy { !$0.acceptsManagedInput }
                                            let remaining = pair(); controller.newLocal(); let closing = controller.selectedTab!.activePane
                                            let three = remaining + [closing]; controller.syncTargets = Set(three.map(\.id)); exitProcesses(three)
                                            wait("threeTargetsEnded", { three.allSatisfy(\.ended) }) {
                                                closing.sendManaged(Array("quit\r".utf8))
                                                checks["closingOnePreservesOtherSyncTargets"] = controller.syncTargets == Set(remaining.map(\.id)) && controller.tabs.count == 2
                                                remaining[0].terminal.insertText("quit\r", replacementRange: NSRange(location: 0, length: 0))
                                                checks["remainingSyncTargetsStillCloseTogether"] = controller.tabs.isEmpty
                                                finish()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension WorkspaceController {
    func sendQuickCommandForTestAll(_ text: String) -> Bool { chooseQuickSendScope(.all); return sendQuickCommand(.init(text: text, appendReturn: true)) }
}
