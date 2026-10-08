// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// A bounded tab strip. The document owns its width instead of relying on the
/// intrinsic size of a stack view inside an unconstrained clip view.
final class TabStripView: NSView {
    static let barHeight: CGFloat = 30
    private final class Scroll: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            guard let documentView else { return }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            let limit = max(0, documentView.bounds.width - contentView.bounds.width)
            let x = min(limit, max(0, contentView.bounds.minX - delta * (event.hasPreciseScrollingDeltas ? 1 : 16)))
            contentView.scroll(to: NSPoint(x: x, y: 0)); reflectScrolledClipView(contentView)
        }
    }
    private final class Document: NSView { override var isFlipped: Bool { true } }
    final class Item: NSView, NSDraggingSource {
        final class TitleButton: NSButton {
            var makeMenu: (() -> NSMenu?)?
            var trackDrag: ((NSEvent) -> Bool)?
            override func mouseDown(with event: NSEvent) {
                if trackDrag?(event) == true { return }; super.mouseDown(with: event)
            }
            override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
        }
        let id: UUID
        let selectButton = TitleButton()
        let closeButton = NSButton()
        var onSelect: (() -> Void)?
        var onClose: (() -> Void)?
        var onDuplicate: (() -> Void)?
        var makeMenu: (() -> NSMenu?)?
        var dragEnabled = false
        var onDragEnd: (() -> Void)?
        func track(_ event: NSEvent) -> Bool {
            guard dragEnabled, !event.modifierFlags.contains(.control), event.clickCount == 1, let window else { return false }
            let start = event.locationInWindow
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { onSelect?(); return true }
                let point = next.locationInWindow
                if hypot(point.x - start.x, point.y - start.y) < 5 { continue }
                let pasteboard = NSPasteboardItem(); pasteboard.setString(id.uuidString, forType: TabDropHost.pasteboardType)
                let item = NSDraggingItem(pasteboardWriter: pasteboard)
                let image = NSImage(size: bounds.size); image.lockFocus()
                NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: 6, yRadius: 6).fill()
                (selectButton.title as NSString).draw(at: NSPoint(x: 10, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]); image.unlockFocus()
                item.setDraggingFrame(bounds, contents: image)
                beginDraggingSession(with: [item], event: next, source: self); return true
            }
            return true
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDragEnd?() }
        var selected = false { didSet { needsDisplay = true } }
        var hasUnreadOutput = false { didSet { if oldValue != hasUnreadOutput { needsDisplay = true } } }
        var preferredWidth: CGFloat = 160
        init(id: UUID) {
            self.id = id
            super.init(frame: .zero)
            selectButton.isBordered = false
            selectButton.font = .systemFont(ofSize: 12, weight: .medium)
            selectButton.alignment = .left; selectButton.lineBreakMode = .byTruncatingTail
            selectButton.target = self; selectButton.action = #selector(selectItem)
            selectButton.makeMenu = { [weak self] in self?.makeMenu?() }
            selectButton.trackDrag = { [weak self] in self?.track($0) ?? false }
            closeButton.isBordered = false
            closeButton.image = NSImage(oshellSymbolName: "xmark", accessibilityDescription: "关闭标签")
            closeButton.imageScaling = .scaleProportionallyDown
            closeButton.target = self; closeButton.action = #selector(closeItem)
            addSubview(selectButton); addSubview(closeButton)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            selectButton.frame = NSRect(x: 18, y: 0, width: max(0, bounds.width - 48), height: bounds.height)
            closeButton.frame = NSRect(x: bounds.width - 26, y: 0, width: 22, height: bounds.height)
        }
        override func draw(_ dirtyRect: NSRect) {
            (selected ? NSColor.oshellAccentColor.withAlphaComponent(0.18) : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
            if selected {
                NSColor.oshellAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: 2), xRadius: 1, yRadius: 1).fill()
            }
            if hasUnreadOutput {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: 9, y: floor((bounds.height - 6) / 2), width: 6, height: 6)).fill()
            }
        }
        @objc private func selectItem() { if NSApp.currentEvent?.clickCount == 2 { onDuplicate?() } else { onSelect?() } }
        @objc private func closeItem() { onClose?() }
        override func mouseDown(with event: NSEvent) { if track(event) { return }; if event.clickCount == 2 { onDuplicate?() } else { onSelect?() } }
        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    }
    private let scroll = Scroll()
    private let document = Document()
    private let addButton = NSButton()
    private let groupButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var groupWidth: CGFloat = 0
    var backgroundMenu: (() -> NSMenu?)?
    private let listButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var items = [Item]()
    private var selectedID: UUID?
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onDuplicate: ((UUID) -> Void)?
    var onAdd: (() -> Void)?
    var contextMenu: ((UUID) -> NSMenu?)?
    var allowsTabDragging = false
    var onDragEnd: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        // No reserved scroller track, including macOS's “Always” preference.
        // Wheel/trackpad, keyboard navigation and the all-tabs menu remain available.
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        addButton.image = NSImage(oshellSymbolName: "plus", accessibilityDescription: "新建本地标签")
        addButton.isBordered = false; addButton.toolTip = "新建本地标签"
        addButton.target = self; addButton.action = #selector(addTab)
        listButton.isBordered = false; listButton.toolTip = "所有标签"
        listButton.setAccessibilityLabel("所有标签")
        groupButton.isBordered = false; groupButton.font = .systemFont(ofSize: 11, weight: .semibold); groupButton.isHidden = true
        [scroll, groupButton, addButton, listButton].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func menu(for event: NSEvent) -> NSMenu? { backgroundMenu?() }
    func setGroup(title: String, menu: NSMenu, active: Bool, unread: Bool) {
        groupButton.isHidden = false
        let caption = (unread ? "● " : "") + title
        menu.insertItem(NSMenuItem(title: caption, action: nil, keyEquivalent: ""), at: 0)
        groupButton.menu = menu; groupButton.toolTip = title + " · 标签组操作"
        groupButton.setAccessibilityLabel("标签组 " + title)
        groupButton.oshellContentTintColor = unread ? .systemOrange : (active ? .oshellAccentColor : .labelColor)
        groupWidth = min(120, max(76, (caption as NSString).size(withAttributes: [.font: groupButton.font!]).width + 24))
        needsLayout = true
    }
    struct Entry {
        let id: UUID
        let title: String
        let detail: String
        var hasUnreadOutput = false
        var number: Int? = nil
    }
    func setAddDescription(_ title: String) { addButton.toolTip = title; addButton.setAccessibilityLabel(title) }
    func update(tabs: [TerminalTab], selected: TerminalTab?, numbers: [UUID: Int]? = nil) {
        let numbers = numbers ?? Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset + 1) })
        update(entries: tabs.map { tab in
            let title = tab.activePane.title
            return Entry(id: tab.id, title: title, detail: tab.activePane.connectionDetails + "\n\n\(tab.layout.panes.count) 个终端 · 双击新建相同会话", hasUnreadOutput: tab.hasUnreadOutput, number: numbers[tab.id])
        }, selectedID: selected?.id)
    }
    func update(entries: [Entry], selectedID: UUID?) {
        if items.map(\.id) != entries.map(\.id) {
            items.forEach { $0.removeFromSuperview() }
            items = entries.map { entry in
                let item = Item(id: entry.id)
                item.dragEnabled = allowsTabDragging
                item.onDragEnd = { [weak self] in self?.onDragEnd?() }
                item.onSelect = { [weak self] in self?.onSelect?(entry.id) }
                item.onDuplicate = { [weak self] in self?.onDuplicate?(entry.id) }
                item.onClose = { [weak self] in self?.onClose?(entry.id) }
                item.makeMenu = { [weak self] in self?.contextMenu?(entry.id) }
                document.addSubview(item); return item
            }
        }
        self.selectedID = selectedID
        let menu = NSMenu(); menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        for (index, entry) in entries.enumerated() {
            let item = items[index], number = entry.number ?? index + 1
            let title = entry.number.map { "\($0)  \(entry.title)" } ?? entry.title
            item.selectButton.title = title; item.hasUnreadOutput = entry.hasUnreadOutput
            item.selectButton.oshellContentTintColor = entry.hasUnreadOutput ? .systemOrange : .labelColor
            item.selectButton.font = .systemFont(ofSize: 12, weight: entry.hasUnreadOutput ? .bold : .medium)
            item.selected = entry.id == selectedID
            item.selectButton.setAccessibilityLabel("标签 \(number)：\(entry.title)")
            item.selectButton.setAccessibilityValue((item.selected ? "已选中" : "未选中") + (entry.hasUnreadOutput ? "，有未读输出" : ""))
            item.toolTip = "\(number). \(entry.title)\n" + (entry.hasUnreadOutput ? "有新输出，切换查看后清除提示\n" : "") + entry.detail
            if let number = entry.number { item.toolTip = (item.toolTip ?? "") + (number <= 9 ? "\n" + ShortcutRuntime.hint(ShortcutAction(rawValue: "tab\(number)")!) + " 跳转" : "\n" + ShortcutRuntime.hint(.tabNumber) + " 输入编号跳转") }
            item.selectButton.toolTip = item.toolTip
            item.closeButton.toolTip = "关闭“\(title)”"; item.closeButton.setAccessibilityLabel("关闭“\(title)”")
            item.preferredWidth = min(320, max(120, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold)]).width + 48))
            let choice = NSMenuItem(title: (entry.hasUnreadOutput ? "● " : "") + "\(number). \(entry.title)" + (entry.hasUnreadOutput ? "（新输出）" : ""), action: #selector(selectFromList(_:)), keyEquivalent: "")
            choice.representedObject = entry.id; choice.target = self; choice.state = item.selected ? .on : .off
            menu.addItem(choice)
        }
        let unread = entries.filter(\.hasUnreadOutput).count
        listButton.oshellContentTintColor = unread > 0 ? .systemOrange : nil
        listButton.toolTip = unread > 0 ? "所有标签 · \(unread) 个有未读输出" : "所有标签"
        listButton.setAccessibilityValue(unread > 0 ? "\(unread) 个标签有未读输出" : "无未读输出")
        listButton.menu = menu; listButton.isEnabled = !entries.isEmpty; needsLayout = true
    }
    override func layout() {
        super.layout()
        let leading = groupButton.isHidden ? 0 : groupWidth + 4
        groupButton.frame = NSRect(x: 2, y: 2, width: groupWidth, height: max(0, bounds.height - 4))
        scroll.frame = NSRect(x: leading, y: 0, width: max(0, bounds.width - 60 - leading), height: bounds.height)
        let buttonHeight = min(24, bounds.height), buttonY = floor((bounds.height - buttonHeight) / 2)
        addButton.frame = NSRect(x: bounds.width - 56, y: buttonY, width: 24, height: buttonHeight)
        listButton.frame = NSRect(x: bounds.width - 28, y: buttonY, width: 24, height: buttonHeight)
        let contentWidth = items.reduce(CGFloat(5)) { $0 + $1.preferredWidth + 3 }
        document.setFrameSize(NSSize(width: max(scroll.contentSize.width, contentWidth), height: scroll.contentSize.height))
        scroll.tile()
        let height = scroll.contentSize.height
        document.setFrameSize(NSSize(width: max(scroll.contentSize.width, contentWidth), height: height))
        let itemHeight = min(26, max(0, height - 4))
        var x: CGFloat = 4
        for item in items {
            item.frame = NSRect(x: x, y: floor((height - itemHeight) / 2), width: item.preferredWidth, height: itemHeight)
            x += item.preferredWidth + 3
        }
    }
    func revealSelection() {
        layoutSubtreeIfNeeded()
        if let item = items.first(where: { $0.id == selectedID }) { document.scrollToVisible(item.frame.insetBy(dx: -4, dy: 0)) }
    }
    var selectedIsVisible: Bool {
        guard let item = items.first(where: { $0.id == selectedID }) else { return items.isEmpty }
        return document.visibleRect.contains(item.frame)
    }
    @objc private func addTab() { onAdd?() }
    @objc private func selectFromList(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onSelect?(id) }
    }
}
