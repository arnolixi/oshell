// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Exercise the actual TerminalView input route and real PTY exits.
enum EndedSessionTest {
    static func run(_ controller: WorkspaceController) {
        var failures = [String](), checks = 0
        func check(_ condition: Bool, _ message: String) { checks += 1; if !condition { failures.append(message) } }
        func send(_ pane: TerminalPane, _ text: String) { pane.terminal.send(source: pane.terminal, data: Array(text.utf8)[...]) }
        func finish() {
            let report: [String: Any] = ["passed": failures.isEmpty, "checks": checks, "failures": failures]
            let path = ProcessInfo.processInfo.environment["OSHELL_ENDED_OUTPUT"] ?? "/tmp/oshell-ended-result.json"
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
            print(report); controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ predicate: @escaping () -> Bool, then action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(10)
            func poll() {
                if predicate() { action() }
                else if Date() > deadline { check(false, "Timed out waiting for PTY output/exit"); finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
            }
            poll()
        }
        controller.newLocal(); let survivor = controller.selectedTab!
        controller.newLocal(); let closing = controller.selectedTab!, pane = closing.activePane
        send(pane, "printf 'BEFORE_DISCONNECT_MARKER\\n'\r")
        wait({ String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("BEFORE_DISCONNECT_MARKER") }) {
            send(pane, "exit\r") // While alive this must reach the shell, not close the tab.
            wait({ pane.ended }) {
                check(controller.tabs.contains(where: { $0 === closing }), "shell exit retains the tab")
                let text = String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                check(text.contains("BEFORE_DISCONNECT_MARKER"), "history remains visible")
                check(text.contains("OShell >") && text.contains("exit") && text.contains("quit"), "local close prompt remains visible")
                send(pane, "echo exit\r")
                check(controller.tabs.count == 2, "unknown local command does not close tab")
                send(pane, "exiy\u{7f}t")
                check(controller.tabs.count == 2, "requires Return")
                controller.select(survivor)
                send(pane, "\r")
                check(controller.tabs.count == 1 && controller.selectedTab === survivor, "closes originating tab, preserves selected live tab")
                let survivorPane = survivor.activePane
                // Abrupt process termination models a dropped SSH connection.
                kill(survivorPane.terminal.process.shellPid, SIGKILL)
                wait({ survivorPane.ended }) {
                    send(survivorPane, "quit\r\nexit\r")
                    check(controller.tabs.isEmpty && controller.selectedTab == nil, "quit closes last tab once")
                    check(controller.window?.isVisible == true, "last close retains workspace window")
                    controller.newLocal(); controller.splitVertical()
                    let split = controller.selectedTab!
                    for child in split.layout.panes { send(child, "exit\r") }
                    wait({ split.layout.panes.allSatisfy(\.ended) }) {
                        send(split.layout.panes[0], "quit\r")
                        check(controller.tabs.isEmpty, "ended split command closes its containing tab")
                        finish()
                    }
                }
            }
        }
    }
}
