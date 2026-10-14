// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore
import SwiftTerm

enum CommandInputTest {
    static func run(_ workspace: WorkspaceController) {
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in exercise(workspace) }
        RunLoop.main.add(timer, forMode: .common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        // Preserve every clipboard representation while checking actual terminal copy paths.
        let clipboard = NSPasteboard.general
        let savedClipboard = (clipboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let saved = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { saved.setData(data, forType: type) } }
            return saved
        }
        func restoreClipboard() { clipboard.clearContents(); clipboard.writeObjects(savedClipboard) }
        let ascii = "curl --url 'https://example.test/path' -H \"accept: */*\"; echo a...b -- --help"
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func later(_ body: @escaping () -> Void) {
            let timer = Timer(timeInterval: 0.15, repeats: false) { _ in body() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func verifyLiteral(_ view: NSTextView, _ label: String) {
            view.isAutomaticQuoteSubstitutionEnabled = true
            view.isAutomaticDashSubstitutionEnabled = true
            view.isAutomaticTextReplacementEnabled = true
            view.isAutomaticSpellingCorrectionEnabled = true
            view.smartInsertDeleteEnabled = true
            checks[label + "SubstitutionsStayDisabled"] = !view.isAutomaticQuoteSubstitutionEnabled && !view.isAutomaticDashSubstitutionEnabled && !view.isAutomaticTextReplacementEnabled && !view.isAutomaticSpellingCorrectionEnabled && !view.smartInsertDeleteEnabled && view.enabledTextCheckingTypes == 0
            view.string = ""; view.setSelectedRange(NSRange(location: 0, length: 0))
            for character in ascii { view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            view.checkTextInDocument(nil)
            checks[label + "ASCIIRetained"] = view.string == ascii
        }
        workspace.newBlankTab()
        let initial = "curl --url 'https://example.test/' \\\n  -H 'accept: text/html'\n中文文件：Ａ.txt"
        let unicode = "\n中文，标点 ＡＢＣ１２３ ‘原样’"
        later {
            guard let window = NSApp.modalWindow, let root = window.contentView,
                  let editor = descendants(root).compactMap({ $0 as? CommandTextView }).first else { checks["previewEditor"] = false; NSApp.abortModal(); return }
            checks["previewEditor"] = true
            checks["previewHasTextLayout"] = editor.textStorage != nil && editor.textContainer != nil && editor.frame.width > 100
            checks["previewDoesNotRewriteClipboard"] = editor.string == initial
            checks["previewInitiallyFocused"] = window.firstResponder === editor
            verifyLiteral(editor, "preview")
            editor.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            checks["chineseCompositionSupported"] = editor.hasMarkedText()
            editor.insertText("中文，标点", replacementRange: NSRange(location: NSNotFound, length: 0))
            checks["chineseCompositionCommits"] = !editor.hasMarkedText() && editor.string == ascii + "\n中文，标点"
            editor.insertText(" ＡＢＣ１２３ ‘原样’", replacementRange: NSRange(location: NSNotFound, length: 0))
            later {
                checks["delayedCheckingDoesNotRewrite"] = editor.string == ascii + unicode
                descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "粘贴" }?.performClick(nil)
            }
        }
        let accepted = InputDialogs.previewPaste(initial, destinations: "隔离测试")
        checks["confirmedTextIsExact"] = accepted?.text == ascii + unicode
        checks["previewOptOutDefaultsOff"] = accepted?.disableFuturePreview == false
        later { if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
        checks["cancelDoesNotReturnText"] = InputDialogs.previewPaste(initial, destinations: "隔离测试") == nil
        if let pane = workspace.selectedTab?.activePane {
            func previewAction(confirm: Bool) {
                later {
                    guard let root = NSApp.modalWindow?.contentView else { checks["previewShown"] = false; return }
                    let views = descendants(root)
                    let checkbox = views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "paste.disablePreview" }
                    checks["previewCheckboxExists"] = checkbox != nil
                    if let checkbox, let editor = views.compactMap({ $0 as? CommandTextView }).first {
                        let boxRect = checkbox.convert(checkbox.bounds, to: root)
                        let editorRect = editor.enclosingScrollView!.convert(editor.enclosingScrollView!.bounds, to: root)
                        checks["previewCheckboxBelowEditor"] = boxRect.maxY <= editorRect.minY
                        checkbox.state = .on
                    }
                    views.compactMap { $0 as? NSButton }.first { $0.title == (confirm ? "粘贴" : "取消") }?.performClick(nil)
                }
            }
            previewAction(confirm: false)
            workspace.pasteText(" \n ", from: pane)
            checks["cancelOptOutKeepsPreference"] = workspace.configuration.preferences.confirmMultilinePaste
            previewAction(confirm: true)
            workspace.pasteText(" \n ", from: pane)
            checks["optOutPersists"] = !workspace.configuration.preferences.confirmMultilinePaste && (try? workspace.store.load().preferences.confirmMultilinePaste) == false
            later {
                if let window = NSApp.modalWindow { checks["optOutSkipsNextPreview"] = false; _ = PopupKeyboard.dismiss(window: window) }
            }
            checks["optOutSkipsNextPreview"] = true
            workspace.pasteText(" \n ", from: pane)
            // Let the optional modal watchdog finish before opening settings.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            later {
                guard let root = NSApp.modalWindow?.contentView else { checks["settingsShown"] = false; return }
                root.layoutSubtreeIfNeeded()
                let views = descendants(root), buttons = views.compactMap { $0 as? NSButton }
                let preview = buttons.first { $0.identifier?.rawValue == "settings.paste.preview" }
                checks["settingsReflectsOptOut"] = preview?.state == .off
                preview?.state = .on
                for id in ["settings.copy.trimLeading", "settings.copy.trimTrailing"] {
                    let button = buttons.first { $0.identifier?.rawValue == id }
                    checks[id + ".defaultOff"] = button?.state == .off
                    button?.state = .on
                }
                if let page = views.first(where: { $0 is GeneralSettingsView }) {
                    checks["copySettingsFitPage"] = descendants(page).filter { $0 is NSButton || $0 is NSTextField }.allSatisfy { page.bounds.contains($0.convert($0.bounds, to: page)) }
                }
                buttons.first { $0.title == "应用" }?.performClick(nil)
            }
            workspace.showPreferences()
            checks["settingsCanReenablePreview"] = workspace.configuration.preferences.confirmMultilinePaste && (try? workspace.store.load().preferences.confirmMultilinePaste) == true
            checks["copyOptionsSaved"] = (try? workspace.store.load().preferences.copyTrimLeadingWhitespace) == true && (try? workspace.store.load().preferences.copyTrimTrailingWhitespace) == true
            let terminal = pane.terminal
            terminal.feed(text: "\u{1b}c  alpha  beta   ")
            terminal.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 15, row: 0))
            terminal.copy(terminal)
            checks["manualCopyUsesLiveSettings"] = clipboard.string(forType: .string) == "alpha  beta"
            terminal.selectAll(nil)
            checks["autoCopyUsesLiveSettings"] = clipboard.string(forType: .string) == "alpha  beta"
            terminal.feed(text: "\u{1b}c   ")
            terminal.selectAll(nil)
            terminal.copy(terminal)
            checks["allWhitespaceDoesNotKeepStaleClipboard"] = clipboard.string(forType: .string) == ""
        }
        workspace.toggleComposer()
        checks["composerUsesLiteralEditor"] = workspace.composer.editor is CommandTextView
        verifyLiteral(workspace.composer.editor, "composer")
        workspace.window?.makeKeyAndOrderFront(nil); workspace.window?.makeFirstResponder(workspace.quickSendBar.field)
        if let editor = workspace.quickSendBar.field.currentEditor() as? NSTextView {
            checks["quickSendUsesLiteralEditor"] = editor is CommandTextView
            verifyLiteral(editor, "quickSend")
        } else { checks["quickSendUsesLiteralEditor"] = false }
        checks["typingDoesNotSendCommands"] = workspace.quickSendBar.history.isEmpty && workspace.selectedTab?.activePane.isBlank == true
        let report: [String: Any] = ["passed":checks.values.allSatisfy { $0 }, "checks":checks]
        if let output = ProcessInfo.processInfo.environment["OSHELL_COMMAND_INPUT_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output)) }
        print("Command input checks: \(checks.count); failures: \(checks.filter { !$0.value }.keys.sorted())")
        restoreClipboard()
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
