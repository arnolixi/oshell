// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

/// A single compact, horizontally scrolling row, independent of terminal tabs.
final class SessionLinkBar: NSView {
    enum Target: Equatable { case link(UUID), folder(String) }
    struct Entry { let target: Target; let title: String; let detail: String }
    final class LinkButton: NSButton {
        var destination: Target!
        var clicked: (() -> Void)?, makeMenu: (() -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
        @objc func activate() { clicked?() }
    }
    private final class Canvas: NSView {
        var makeMenu: (() -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    }
    private final class Scroll: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            guard let documentView else { return }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            contentView.scroll(to: NSPoint(x: max(0, min(documentView.bounds.width - contentView.bounds.width, contentView.bounds.minX - delta * (event.hasPreciseScrollingDeltas ? 1 : 16))), y: 0))
            reflectScrolledClipView(contentView)
        }
    }
    private let scroll = Scroll(), canvas = Canvas()
    private let all = NSPopUpButton(frame: .zero, pullsDown: true)
    private let hint = NSTextField(labelWithString: "在标签标题上右键，添加会话到快捷链接")
    private(set) var buttons = [LinkButton]()
    var onOpen: ((Target, NSView) -> Void)?
    var makeContextMenu: ((Target?) -> NSMenu?)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none; scroll.documentView = canvas
        canvas.makeMenu = { [weak self] in self?.makeContextMenu?(nil) }
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        all.isBordered = false; all.toolTip = "所有快捷链接"; all.setAccessibilityLabel("所有快捷链接")
        addSubview(scroll); addSubview(all); canvas.addSubview(hint)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu?(nil) }
    func update(_ entries: [Entry], menu: NSMenu) {
        buttons.forEach { $0.removeFromSuperview() }; buttons = []
        for entry in entries {
            let button = LinkButton(); button.destination = entry.target; button.title = entry.title
            button.isBordered = false; button.font = .systemFont(ofSize: 12); button.lineBreakMode = .byTruncatingTail
            let folder: Bool; if case .folder = entry.target { folder = true } else { folder = false }
            button.image = NSImage(oshellSymbolName: folder ? "folder" : "terminal", accessibilityDescription: nil)
            button.imagePosition = .imageLeading; button.imageScaling = .scaleProportionallyDown
            button.toolTip = entry.detail; button.setAccessibilityLabel(entry.title)
            button.target = button; button.action = #selector(LinkButton.activate)
            button.clicked = { [weak self, weak button] in guard let button else { return }; self?.onOpen?(entry.target, button) }
            button.makeMenu = { [weak self] in self?.makeContextMenu?(entry.target) }
            canvas.addSubview(button); buttons.append(button)
        }
        hint.isHidden = !entries.isEmpty
        let heading = NSMenuItem(title: "", action: nil, keyEquivalent: ""); menu.insertItem(heading, at: 0)
        all.menu = menu; needsLayout = true
    }
    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 6, y: 0, width: max(0, bounds.width - 38), height: bounds.height)
        all.frame = NSRect(x: max(0, bounds.width - 30), y: 3, width: 24, height: 24)
        var x: CGFloat = 0
        for button in buttons {
            let width = min(220, max(64, (button.title as NSString).size(withAttributes: [.font: button.font!]).width + 30))
            button.frame = NSRect(x: x, y: 2, width: width, height: 26); x += width + 8
        }
        canvas.setFrameSize(NSSize(width: max(scroll.contentSize.width, x), height: max(0, bounds.height)))
        hint.frame = NSRect(x: 8, y: 7, width: max(0, scroll.contentSize.width - 16), height: 17)
    }
}
