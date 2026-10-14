// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum QuickSendTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool](), finished = false
        func text(_ pane: TerminalPane) -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func finish() {
            guard !finished else { return }; finished = true
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            let path = ProcessInfo.processInfo.environment["OSHELL_QUICKSEND_OUTPUT"] ?? "/tmp/oshell-quicksend.json"
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            print(report); controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(10)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; action() }
                else if Date() >= deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() } }
            }
            poll()
        }
        func submit(_ marker: String) {
            controller.quickSendBar.fill(QuickSendEntry(text: "printf '\(marker)\\n'", appendReturn: true))
            if let editor = controller.quickSendBar.field.currentEditor() as? NSTextView {
                checks["returnUsesFieldEditor"] = controller.quickSendBar.control(controller.quickSendBar.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            } else { checks["returnUsesFieldEditor"] = false; controller.quickSendBar.submit() }
        }
        checks["composerInitiallyLazy"] = controller.loadedComposer == nil
        checks["defaultScopeIsCurrent"] = controller.quickSendScope == .current
        controller.newLocal(); let group = controller.selectedTab!, first = group.activePane
        controller.splitVertical(); let peer = group.activePane
        controller.newLocal(); let second = controller.selectedTab!.activePane
        controller.newLocal(); let third = controller.selectedTab!.activePane
        let all = [first, peer, second, third]
        submit("QUICK_CURRENT_OK")
        wait("currentReceived", { text(third).contains("\nQUICK_CURRENT_OK\n") }) {
            checks["currentExcludesOthers"] = [first, peer, second].allSatisfy { !text($0).contains("QUICK_CURRENT_OK") }
            checks["sendClearsDraftAndRemembers"] = controller.quickSendBar.field.stringValue.isEmpty && controller.quickSendBar.history.count == 1
            controller.select(group); controller.chooseQuickSendScope(.tab)
            submit("QUICK_GROUP_OK")
            wait("groupReceived", { [first, peer].allSatisfy { text($0).contains("\nQUICK_GROUP_OK\n") } }) {
                checks["groupExcludesOtherTabs"] = [second, third].allSatisfy { !text($0).contains("QUICK_GROUP_OK") }
                controller.chooseQuickSendScope(.all); submit("QUICK_ALL_OK")
                wait("allReceived", { all.allSatisfy { text($0).contains("\nQUICK_ALL_OK\n") } }) {
                    controller.chooseQuickSendScope(.visible)
                    checks["visibleTabbedScope"] = Set(controller.quickSendTargets.map(\.id)) == Set([first.id, peer.id])
                    controller.arrange(.tiled); controller.window?.contentView?.layoutSubtreeIfNeeded()
                    checks["visibleTiledScope"] = Set(controller.quickSendTargets.map(\.id)) == Set(all.map(\.id))
                    submit("QUICK_VISIBLE_OK")
                    wait("visibleReceived", { all.allSatisfy { text($0).contains("\nQUICK_VISIBLE_OK\n") } }) {
                        controller.quickSendScope = .selected; controller.quickSendSelected = [first.id, second.id]
                        controller.syncTargets = Set(all.map(\.id)); controller.refreshOperatorState()
                        submit("QUICK_SELECTED_OK")
                        wait("selectedReceived", { [first, second].allSatisfy { text($0).contains("\nQUICK_SELECTED_OK\n") } }) {
                            checks["selectedIndependentOfSync"] = [peer, third].allSatisfy { !text($0).contains("QUICK_SELECTED_OK") }
                            checks["selectedNotDuplicated"] = [first, second].allSatisfy { text($0).components(separatedBy: "\nQUICK_SELECTED_OK\n").count == 2 }
                            controller.stopSyncInput()
                            let bar = controller.quickSendBar
                            let command = QuickCommand(name: "待发送", group: "测试", text: "printf 'NOT_SENT_BY_SELECTION\\n'")
                            var config = controller.configuration; config.quickCommands = [command]; checks["savedCommandPersists"] = controller.saveConfiguration(config)
                            bar.rebuildHistoryMenu()
                            let item = bar.historyButton.menu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == command.name }
                            if let item { bar.chooseEntry(item) }
                            checks["savedSelectionOnlyFills"] = item != nil && bar.field.stringValue == command.text && all.allSatisfy { !text($0).contains("NOT_SENT_BY_SELECTION") }
                            bar.browseHistory(older: true)
                            checks["historyUpLoadsLast"] = bar.field.stringValue.contains("QUICK_SELECTED_OK")
                            bar.browseHistory(older: false)
                            checks["historyDownRestoresDraft"] = bar.field.stringValue == command.text
                            bar.fill(QuickSendEntry(text: "", appendReturn: true))
                            if let editor = bar.field.currentEditor() as? NSTextView { editor.insertText("echo MULTI_ONE\necho MULTI_TWO", replacementRange: NSRange(location: 0, length: 0)) }
                            checks["multilineInputOpensComposer"] = controller.loadedComposer?.editor.string == "echo MULTI_ONE\necho MULTI_TWO" && controller.loadedComposer?.isHidden == false
                            checks["multilinePreservesScope"] = controller.composerTargets == [first.id, second.id]
                            checks["multilineNotExecuted"] = all.allSatisfy { !text($0).contains("MULTI_ONE") }
                            if controller.loadedComposer?.isHidden == false { controller.toggleComposer() }
                            bar.fill(QuickSendEntry(text: "", appendReturn: true))
                            if let editor = bar.field.currentEditor() as? NSTextView {
                                let historyCount = bar.history.count
                                editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
                                checks["markedTextReturnDoesNotSend"] = !bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) && bar.history.count == historyCount
                                editor.unmarkText()
                            } else { checks["markedTextReturnDoesNotSend"] = false }
                            let longEntry = QuickSendEntry(text: String(repeating: "x", count: 8192), appendReturn: true)
                            for index in 0..<70 { bar.remember(QuickSendEntry(text: "\(index)" + longEntry.text.dropFirst(3), appendReturn: true)) }
                            checks["historyBounded"] = bar.history.count <= 50 && bar.history.reduce(0, { $0 + $1.text.utf8.count }) <= 65536
                            controller.chooseQuickSendScope(.all); third.shutdown(); controller.refreshOperatorState()
                            checks["closedPaneExcluded"] = !controller.quickSendTargets.contains { $0 === third } && bar.scopeButton.toolTip?.contains("跳过 1") == true
                            for size in [NSSize(width: 760, height: 460), NSSize(width: 1180, height: 760)] {
                                controller.window?.setContentSize(size); controller.window?.contentView?.layoutSubtreeIfNeeded()
                                checks["barGeometry\(Int(size.width))"] = descendants(bar).filter { $0 is NSControl }.allSatisfy { bar.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: bar)) } && bar.field.bounds.width >= 120
                            }
                            controller.toggleQuickSendBar()
                            checks["barHidePersists"] = bar.isHidden && (try? controller.store.load().preferences.quickSendBarVisible) == false
                            controller.focusQuickSendBar()
                            checks["focusShortcutShowsBar"] = !bar.isHidden && bar.field.currentEditor() != nil
                            controller.quickSendBar.onEscape?()
                            checks["escapeReturnsToTerminal"] = controller.window?.firstResponder === controller.selectedTab?.activePane.terminal
                            bar.fill(QuickSendEntry(text: "uptime", appendReturn: true))
                            if let root = controller.window?.contentView,
                               let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                                root.cacheDisplay(in: root.bounds, to: bitmap)
                                // cacheDisplay does not include the window background or Metal layers.
                                let preview = NSImage(size: root.bounds.size)
                                preview.lockFocus()
                                NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: root.bounds.size)).fill()
                                bitmap.draw(in: NSRect(origin: .zero, size: root.bounds.size)); preview.unlockFocus()
                                if let tiff = preview.tiffRepresentation, let rendered = NSBitmapImageRep(data: tiff), let image = rendered.representation(using: .png, properties: [:]),
                                   let path = ProcessInfo.processInfo.environment["OSHELL_QUICKSEND_IMAGE"] { try? image.write(to: URL(fileURLWithPath: path)) }
                            }
                            finish()
                        }
                    }
                }
            }
        }
    }
}
