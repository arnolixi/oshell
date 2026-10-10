// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Keep tab navigation out of the PTY, including while xterm owns keyboard focus.
final class WorkspaceWindow: NSWindow {
    private func navigate(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isKeyWindow, attachedSheet == nil, NSApp.modalWindow == nil,
              let workspace = windowController as? WorkspaceController else { return false }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if event.keyCode == 53, flags.isEmpty {
            if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            if let terminal = firstResponder as? OShellTerminal, terminal.hasMarkedText() { return false }
        }
        if event.keyCode == 53, flags.isEmpty, let pane = workspace.selectedTab?.activePane, !pane.searchPanel.isHidden,
           firstResponder === pane.terminal || pane.searchPanel.ownsKeyboardFocus {
            if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            pane.searchPanel.hide(); return true
        }
        if event.keyCode == 53, flags.isEmpty, workspace.isFocusFullscreen || workspace.focusFullscreenRequested {
            workspace.requestFocusFullscreen(false); return true
        }
        let shortcut = KeyboardShortcut(event: event)
        guard workspace.isSecurityUnlocked, shortcut.isValid,
              let action = workspace.configuration.preferences.keyboardShortcuts.action(for: shortcut) else { return false }
        if action == .focusFullscreen && event.isARepeat { return true }
        return workspace.dispatchShortcut(action)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        navigate(event) || super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if navigate(event) { return }
        super.sendEvent(event)
    }
}
