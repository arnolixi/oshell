// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum OperatorInputTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool](), finished = false
        func text(_ pane: TerminalPane) -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func finish() {
            guard !finished else { return }; finished = true
            let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            let path = ProcessInfo.processInfo.environment["OSHELL_OPERATOR_OUTPUT"] ?? "/tmp/oshell-operator-result.json"
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            print(result); controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ label: String, condition: @escaping () -> Bool, then action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(12)
            func poll() { guard !finished else { return }; if condition() { checks[label] = true; action() } else if Date() > deadline { checks[label] = false; finish() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) } }
            poll()
        }
        controller.newLocal(); let first = controller.selectedTab!.activePane
        controller.newLocal(); let second = controller.selectedTab!.activePane
        controller.newLocal(); let excluded = controller.selectedTab!.activePane
        controller.composerTargets = [first.id, second.id]
        controller.sendComposed("printf 'COMPOSER_TEST_OK\\n'", appendReturn: true)
        wait("composerSendsToBoth", condition: { text(first).contains("\nCOMPOSER_TEST_OK\n") && text(second).contains("\nCOMPOSER_TEST_OK\n") }) {
            checks["composerExcludesUnselected"] = !text(excluded).contains("COMPOSER_TEST_OK")
            controller.syncTargets = [first.id, second.id]
            first.terminal.insertText("printf 'SYNC_TEST_OK\\n'\r", replacementRange: NSRange(location: 0, length: 0))
            wait("actualTypingBroadcast", condition: { text(first).contains("\nSYNC_TEST_OK\n") && text(second).contains("\nSYNC_TEST_OK\n") }) {
                checks["typingExcludesUnselected"] = !text(excluded).contains("SYNC_TEST_OK")
                first.terminal.send(source: first.terminal, data: Array("printf 'REPLY_SOURCE_ONLY\\n'\r".utf8)[...])
                wait("protocolReplyReachesSource", condition: { text(first).contains("\nREPLY_SOURCE_ONLY\n") }) {
                    checks["protocolReplyNotBroadcast"] = !text(second).contains("REPLY_SOURCE_ONLY")
                    controller.configuration.preferences.confirmMultilinePaste = false
                    controller.pasteText("printf 'PASTE_FIRST_OK\\n'\nprintf 'PASTE_SECOND_OK\\n'", from: first)
                    first.terminal.insertText("\r", replacementRange: NSRange(location: 0, length: 0))
                    wait("multilinePasteBoth", condition: { text(first).contains("\nPASTE_SECOND_OK\n") && text(second).contains("\nPASTE_SECOND_OK\n") }) {
                        checks["pasteExcludesUnselected"] = !text(excluded).contains("PASTE_FIRST_OK")
                        controller.stopSyncInput()
                        first.terminal.insertText("printf 'AFTER_STOP_OK\\n'\r", replacementRange: NSRange(location: 0, length: 0))
                        wait("stopSyncSourceWorks", condition: { text(first).contains("\nAFTER_STOP_OK\n") }) {
                            checks["stopSyncExcludesPeer"] = !text(second).contains("AFTER_STOP_OK")
                            let command = QuickCommand(name: "已保存测试", text: "printf 'QUICK_TEST_OK\\n'")
                            var config = controller.configuration; config.quickCommands = [command]
                            checks["quickCommandSaved"] = controller.saveConfiguration(config)
                            controller.fillComposer(command)
                            checks["quickCommandFillsComposer"] = controller.composer.editor.string == command.text && !controller.composer.isHidden
                            controller.syncTargets = [first.id, second.id]; second.shutdown(); controller.refreshOperatorState()
                            checks["closedTargetStopsSync"] = controller.syncTargets.isEmpty
                            let original = text(first); first.applyHighlights(.standard)
                            checks["highlightKeepsBufferText"] = text(first) == original
                            let matches = first.terminal.foregroundHighlightProvider?("ERROR warning " + first.title) ?? []
                            checks["highlightPresetMatches"] = matches.count >= 3
                            finish()
                        }
                    }
                }
            }
        }
    }
}
