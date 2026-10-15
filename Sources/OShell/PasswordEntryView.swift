// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Marks only a manually entered, temporarily revealed password for Ctrl+A.
final class RevealedPasswordTextField: NSTextField {}

/// Contains new user input only. Never accepts or retrieves a saved credential.
final class PasswordEntryView: NSView, NSTextFieldDelegate {
    let secureField = NSSecureTextField()
    let visibleField = RevealedPasswordTextField()
    let revealButton = NSButton(checkboxWithTitle: "显示密码", target: nil, action: nil)
    private weak var preparedEditor: NSTextView?
    private var editorOptions: [Bool]?
    var isRevealed: Bool { revealButton.state == .on }
    var activeField: NSTextField { isRevealed ? visibleField : secureField }
    var stringValue: String {
        get { activeField.stringValue }
        set { activeField.stringValue = newValue; (isRevealed ? secureField : visibleField).stringValue = "" }
    }
    var placeholderString: String? {
        get { secureField.placeholderString }
        set { secureField.placeholderString = newValue; visibleField.placeholderString = newValue }
    }
    init(identifier: String) {
        super.init(frame: .zero)
        self.identifier = .init(identifier + ".entry")
        secureField.identifier = .init(identifier); visibleField.identifier = .init(identifier + ".visible")
        revealButton.identifier = .init(identifier + ".reveal")
        revealButton.toolTip = "仅显示本次输入的密码；已保存的密码不会回显。"
        secureField.setAccessibilityLabel("密码"); visibleField.setAccessibilityLabel("本次输入的密码（明文）")
        visibleField.isHidden = true
        for field in [secureField as NSTextField, visibleField] {
            field.delegate = self
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.translatesAutoresizingMaskIntoConstraints = false; addSubview(field)
        }
        revealButton.target = self; revealButton.action = #selector(toggleVisibility)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)
        revealButton.translatesAutoresizingMaskIntoConstraints = false; addSubview(revealButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            revealButton.trailingAnchor.constraint(equalTo: trailingAnchor), revealButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        for field in [secureField as NSTextField, visibleField] {
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: leadingAnchor), field.trailingAnchor.constraint(equalTo: revealButton.leadingAnchor, constant: -8), field.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func toggleVisibility() {
        // The button has already toggled its state. Commit any field editor text
        // before moving it, preserving punctuation, Unicode and selection.
        let previous: NSTextField = isRevealed ? secureField : visibleField
        let editor = previous.currentEditor() as? NSTextView
        let selection = editor?.selectedRange()
        if editor != nil, window?.makeFirstResponder(nil) == false {
            revealButton.state = isRevealed ? .off : .on; return
        }
        let value = previous.stringValue
        secureField.isHidden = isRevealed; visibleField.isHidden = !isRevealed
        activeField.stringValue = value; previous.stringValue = ""
        if let window {
            window.makeFirstResponder(activeField)
            if isRevealed, let editor = visibleField.currentEditor() as? NSTextView { prepare(editor) }
            if let selection, let next = activeField.currentEditor() as? NSTextView {
                let length = (value as NSString).length
                let location = min(selection.location, length)
                next.setSelectedRange(NSRange(location: location, length: min(selection.length, length-location)))
            }
        }
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === visibleField, let editor = visibleField.currentEditor() as? NSTextView else { return }
        prepare(editor)
    }
    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        if control === visibleField, let editor = fieldEditor as? NSTextView { prepare(editor) }
        return true
    }
    private func prepare(_ editor: NSTextView) {
        guard preparedEditor !== editor else { return }
        preparedEditor = editor
        editorOptions = [editor.isAutomaticQuoteSubstitutionEnabled, editor.isAutomaticDashSubstitutionEnabled,
                         editor.isAutomaticTextReplacementEnabled, editor.isContinuousSpellCheckingEnabled, editor.isAutomaticSpellingCorrectionEnabled]
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isContinuousSpellCheckingEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
    }
    func controlTextDidEndEditing(_ notification: Notification) { restoreEditorOptions() }
    private func restoreEditorOptions() {
        if let editor = preparedEditor, let options = editorOptions {
            editor.isAutomaticQuoteSubstitutionEnabled = options[0]; editor.isAutomaticDashSubstitutionEnabled = options[1]
            editor.isAutomaticTextReplacementEnabled = options[2]; editor.isContinuousSpellCheckingEnabled = options[3]; editor.isAutomaticSpellingCorrectionEnabled = options[4]
        }
        preparedEditor = nil; editorOptions = nil
    }
    func clear() {
        if let editor = activeField.currentEditor() as? NSTextView { editor.string = ""; window?.makeFirstResponder(nil) }
        secureField.stringValue = ""; visibleField.stringValue = ""
        revealButton.state = .off; secureField.isHidden = false; visibleField.isHidden = true
        restoreEditorOptions()
    }
}
