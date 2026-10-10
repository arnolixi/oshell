// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum PasswordSelectionTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func later(_ body: @escaping () -> Void) {
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in body() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func key(_ window: NSWindow, flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: flags == .control ? "\u{1}" : "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        }
        let original = "fixture-中文-🔐-password", replacement = "replacement-fixture"
        let clipboardChange = NSPasteboard.general.changeCount
        later {
            guard let window = NSApp.modalWindow, let root = window.contentView,
                  let field = descendants(root).compactMap({ $0 as? NSSecureTextField }).first else { checks["passwordPromptOpened"] = false; NSApp.abortModal(); return }
            field.stringValue = original; window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { checks["secureFieldEditorExists"] = false; NSApp.abortModal(); return }
            editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
            NSApp.postEvent(key(window, flags: .control), atStart: false)
            later {
                checks["controlASelectsEntireUnicodePassword"] = editor.selectedRange() == NSRange(location: 0, length: (original as NSString).length)
                checks["selectionDoesNotCopySecret"] = NSPasteboard.general.changeCount == clipboardChange
                editor.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
                checks["typingReplacesWholePassword"] = editor.string == replacement
                editor.setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
                NSApp.postEvent(key(window, flags: .command), atStart: false)
                later {
                    checks["commandAStillSelectsAll"] = editor.selectedRange() == NSRange(location: 0, length: (replacement as NSString).length)
                    checks["modifiedControlANotIntercepted"] = !PopupKeyboard.selectAllPassword(with: key(window, flags: [.control, .shift]), in: window)
                    editor.string = ""; field.stringValue = ""
                    checks["emptyPasswordHandled"] = PopupKeyboard.selectAllPassword(with: key(window, flags: .control), in: window) && editor.selectedRange() == NSRange(location: 0, length: 0)
                    editor.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
                    window.makeFirstResponder(nil)
                    descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "确定" }?.performClick(nil)
                }
            }
        }
        checks["submittedReplacementIsExact"] = PasswordVault.promptMaster(title: "解锁 OShell 加密数据", creating: false) == replacement
        let window = workspace.window!
        workspace.quickSendBar.fill(.init(text: "keep ordinary editing", appendReturn: true))
        checks["ordinaryFieldNotIntercepted"] = !PopupKeyboard.selectAllPassword(with: key(window, flags: .control), in: window)
        workspace.newBlankTab(); let pane = workspace.selectedTab!.activePane
        pane.activate(); window.makeKeyAndOrderFront(nil)
        checks["terminalNotIntercepted"] = !PopupKeyboard.selectAllPassword(with: key(window, flags: .control), in: window)
        var bytes = [UInt8](); let previous = pane.onUserInput
        pane.onUserInput = { _, input in bytes += input; return true }
        window.sendEvent(key(window, flags: .control)); pane.onUserInput = previous
        checks["terminalStillReceivesControlA"] = bytes == [1]
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let output = ProcessInfo.processInfo.environment["OSHELL_PASSWORD_SELECTION_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output)) }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
