// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum PasteScrollTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func later(_ body: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { body(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        workspace.configuration.preferences.metal = false
        workspace.newBlankTab(); let firstTab = workspace.selectedTab!, first = firstTab.activePane
        workspace.newBlankTab(); let second = workspace.selectedTab!.activePane
        workspace.newBlankTab(); let excluded = workspace.selectedTab!.activePane
        workspace.select(firstTab); workspace.window?.contentView?.layoutSubtreeIfNeeded()
        func history(_ pane: TerminalPane) {
            pane.handleEndedInput([21][...]) // Clear fixture input without running a command.
            pane.terminal.feed(text: "\u{1b}c" + (0..<240).map { "history-\($0)\r\n" }.joined() + "input> ")
            pane.terminal.scroll(toPosition: 0.2)
        }
        func atInput(_ pane: TerminalPane) -> Bool { pane.terminal.scrollPosition == 1 }
        history(first)
        checks["fixtureStartsInHistory"] = !atInput(first)
        workspace.pasteText("paste-fixture", from: first)
        checks["singleLineReturnsToInput"] = atInput(first)
        history(first)
        let previous = first.terminal.scrollPosition
        workspace.pasteText("", from: first)
        checks["emptyPasteDoesNotScroll"] = first.terminal.scrollPosition == previous
        later { _ in if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
        workspace.pasteText("bad\0input", from: first)
        checks["invalidPasteDoesNotScroll"] = first.terminal.scrollPosition == previous

        workspace.configuration.preferences.confirmMultilinePaste = true
        later { root in
            checks["previewDoesNotScrollBeforeConfirmation"] = first.terminal.scrollPosition == previous
            views(root).compactMap { $0 as? NSButton }.first { $0.title == "取消" }?.performClick(nil)
        }
        workspace.pasteText(" \n ", from: first)
        checks["cancelPreservesHistoryPosition"] = first.terminal.scrollPosition == previous
        later { root in
            views(root).compactMap { $0 as? CommandTextView }.first?.string = ""
            views(root).compactMap { $0 as? NSButton }.first { $0.title == "粘贴" }?.performClick(nil)
        }
        workspace.pasteText(" \n ", from: first)
        checks["emptyEditedPreviewDoesNotScroll"] = first.terminal.scrollPosition == previous
        later { root in views(root).compactMap { $0 as? NSButton }.first { $0.title == "粘贴" }?.performClick(nil) }
        workspace.pasteText(" \n ", from: first)
        checks["confirmedMultilineReturnsToInput"] = atInput(first)
        history(first)
        workspace.configuration.preferences.confirmMultilinePaste = false
        workspace.pasteText(" \n ", from: first)
        checks["directMultilineReturnsToInput"] = atInput(first)

        for pane in [first, second, excluded] { history(pane) }
        let excludedPosition = excluded.terminal.scrollPosition
        workspace.syncTargets = [first.id, second.id]
        workspace.quickSendBar.fill(.init(text: "preserve draft", appendReturn: false))
        let responder = workspace.window?.firstResponder
        workspace.pasteText("sync-fixture", from: first)
        checks["allPasteTargetsReturnToInput"] = atInput(first) && atInput(second)
        checks["otherSessionsKeepHistoryPosition"] = excluded.terminal.scrollPosition == excludedPosition
        checks["pasteDoesNotStealKeyboardFocus"] = workspace.window?.firstResponder === responder

        history(first); history(second)
        workspace.syncTargets = [first.id, second.id]
        workspace.configuration.preferences.confirmMultilinePaste = true
        let acceptedPosition = first.terminal.scrollPosition
        later { root in
            second.shutdown()
            later { _ in if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
            views(root).compactMap { $0 as? NSButton }.first { $0.title == "粘贴" }?.performClick(nil)
        }
        workspace.pasteText(" \n ", from: first)
        checks["targetClosedDuringPreviewDoesNotScrollOthers"] = first.terminal.scrollPosition == acceptedPosition
        workspace.syncTargets = []
        workspace.configuration.preferences.confirmMultilinePaste = false
        history(first)
        first.terminal.feed(text: "\u{1b}[?1049h")
        let alternateCursor = first.terminal.getTerminal().buffer.yDisp
        workspace.pasteText("alternate-fixture", from: first)
        checks["alternateScreenStaysActive"] = first.terminal.getTerminal().isCurrentBufferAlternate && first.terminal.getTerminal().buffer.yDisp == alternateCursor
        first.terminal.feed(text: "\u{1b}[?1049l")
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let output = ProcessInfo.processInfo.environment["OSHELL_PASTE_SCROLL_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output)) }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
