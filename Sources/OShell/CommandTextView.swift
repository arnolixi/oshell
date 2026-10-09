// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

/// Command input must preserve literal characters. Keep NSTextInputClient/IME
/// behavior intact; never normalize pasted Unicode or change the system input source.
class CommandTextView: NSTextView {
    private var ownedTextStorage: NSTextStorage?
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let resolved: NSTextContainer
        if let container { resolved = container }
        else {
            let storage = NSTextStorage(), layout = NSLayoutManager()
            resolved = NSTextContainer(containerSize: NSSize(width: max(1, frameRect.width), height: CGFloat.greatestFiniteMagnitude))
            resolved.widthTracksTextView = true
            storage.addLayoutManager(layout); layout.addTextContainer(resolved); ownedTextStorage = storage
        }
        super.init(frame: frameRect, textContainer: resolved)
        configureLiteralInput()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); configureLiteralInput() }
    private func configureLiteralInput() {
        isRichText = false; importsGraphics = false
        super.isAutomaticQuoteSubstitutionEnabled = false
        super.isAutomaticDashSubstitutionEnabled = false
        super.isAutomaticTextReplacementEnabled = false
        super.isAutomaticSpellingCorrectionEnabled = false
        super.isAutomaticTextCompletionEnabled = false
        super.isAutomaticLinkDetectionEnabled = false
        super.isAutomaticDataDetectionEnabled = false
        super.isContinuousSpellCheckingEnabled = false
        super.isGrammarCheckingEnabled = false
        super.smartInsertDeleteEnabled = false
        super.enabledTextCheckingTypes = 0
    }
    override func becomeFirstResponder() -> Bool {
        configureLiteralInput()
        return super.becomeFirstResponder()
    }
    override var isAutomaticQuoteSubstitutionEnabled: Bool { get { false } set {} }
    override var isAutomaticDashSubstitutionEnabled: Bool { get { false } set {} }
    override var isAutomaticTextReplacementEnabled: Bool { get { false } set {} }
    override var isAutomaticSpellingCorrectionEnabled: Bool { get { false } set {} }
    override var isAutomaticTextCompletionEnabled: Bool { get { false } set {} }
    override var isAutomaticLinkDetectionEnabled: Bool { get { false } set {} }
    override var isAutomaticDataDetectionEnabled: Bool { get { false } set {} }
    override var isContinuousSpellCheckingEnabled: Bool { get { false } set {} }
    override var isGrammarCheckingEnabled: Bool { get { false } set {} }
    override var smartInsertDeleteEnabled: Bool { get { false } set {} }
    override var enabledTextCheckingTypes: NSTextCheckingTypes { get { 0 } set {} }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let substitutions: [Selector] = [#selector(toggleAutomaticQuoteSubstitution(_:)), #selector(toggleAutomaticDashSubstitution(_:)), #selector(toggleAutomaticTextReplacement(_:)), #selector(toggleAutomaticSpellingCorrection(_:)), #selector(toggleAutomaticTextCompletion(_:)), #selector(toggleSmartInsertDelete(_:))]
        if let action = item.action, substitutions.contains(action) { return false }
        return super.validateUserInterfaceItem(item)
    }
}
