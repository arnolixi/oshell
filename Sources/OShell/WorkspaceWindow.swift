// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

/// Keep tab navigation out of the PTY, including while xterm owns keyboard focus.
final class WorkspaceWindow: NSWindow {
    private func navigate(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isKeyWindow, attachedSheet == nil, NSApp.modalWindow == nil,
              let workspace = windowController as? WorkspaceController else { return false }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f" { workspace.findInTerminal(); return true }
        if event.charactersIgnoringModifiers?.lowercased() == "g", flags == .command { workspace.findNextInTerminal(); return true }
        if event.charactersIgnoringModifiers?.lowercased() == "g", flags == [.command, .shift] { workspace.findPreviousInTerminal(); return true }
        if event.keyCode == 53, flags.isEmpty, let pane = workspace.selectedTab?.activePane, !pane.searchPanel.isHidden,
           firstResponder === pane.terminal || pane.searchPanel.ownsKeyboardFocus {
            if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            pane.searchPanel.hide(); return true
        }
        if event.keyCode == 48, flags == .control { workspace.nextTab(); return true }
        if event.keyCode == 48, flags == [.control, .shift] { workspace.previousTab(); return true }
        if event.keyCode == 50, flags == .control { workspace.lastUsedTab(); return true }
        if flags == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case "]", "}": workspace.nextTab(); return true
            case "[", "{": workspace.previousTab(); return true
            default: break
            }
        }
        return false
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        navigate(event) || super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if navigate(event) { return }
        super.sendEvent(event)
    }
}
