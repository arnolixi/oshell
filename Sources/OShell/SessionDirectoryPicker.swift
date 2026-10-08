// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class SessionDirectoryTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Node: NSObject {
        let path: String
        var children = [Node]()
        init(_ path: String) { self.path = path }
    }
    let outline = NSOutlineView()
    private let selectionLabel = NSTextField(labelWithString: "")
    private let root: Node
    private var nodes = [String: Node]()
    private let excluded: [String]
    var selectedDirectory: String? { (outline.item(atRow: outline.selectedRow) as? Node)?.path }

    init(directories: [String], selected: String, excluded: [String] = [], rootDirectory: String = "") {
        self.excluded = excluded; self.root = Node(SessionDirectory.normalize(rootDirectory))
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 330))
        var config = Configuration(profiles: []); config.directories = directories
        nodes[root.path] = root
        let paths = SessionDirectory.all(config).filter { $0 != root.path && (root.path.isEmpty || SessionDirectory.contains($0, in: root.path)) }
        for path in paths { nodes[path] = Node(path) }
        for path in paths { nodes[SessionDirectory.parent(path)]?.children.append(nodes[path]!) }
        for node in nodes.values { node.children.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }
        let column = NSTableColumn(identifier: .init("directory")); column.width = 414
        outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil
        outline.rowHeight = 28; outline.indentationPerLevel = 16; outline.allowsMultipleSelection = false
        if #available(macOS 11, *) { outline.style = .plain }
        outline.dataSource = self; outline.delegate = self; outline.setAccessibilityLabel("会话目录树")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 28, width: bounds.width, height: bounds.height - 28))
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        selectionLabel.frame = NSRect(x: 4, y: 3, width: bounds.width - 8, height: 20)
        selectionLabel.autoresizingMask = [.width]; selectionLabel.font = .systemFont(ofSize: 11)
        selectionLabel.lineBreakMode = .byTruncatingMiddle; selectionLabel.setAccessibilityLabel("当前选择目录")
        addSubview(scroll); addSubview(selectionLabel); outline.reloadData(); outline.expandItem(root)
        if !selectDirectory(selected) { _ = selectDirectory(root.path) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func selectable(_ path: String) -> Bool { !excluded.contains { SessionDirectory.contains(path, in: $0) } }
    @discardableResult func selectDirectory(_ path: String) -> Bool {
        guard let node = nodes[path], selectable(path) else { return false }
        var parents = [root], parent = SessionDirectory.parent(path)
        while !parent.isEmpty && parent != root.path {
            if let node = nodes[parent] { parents.insert(node, at: 1) }; parent = SessionDirectory.parent(parent)
        }
        for ancestor in parents { outline.expandItem(ancestor) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row)
        return true
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        selectionLabel.stringValue = selectedDirectory.map { "当前选择：" + SessionDirectory.display($0) } ?? "请选择目录"
        selectionLabel.toolTip = selectionLabel.stringValue
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? 1 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? root }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Node).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { selectable((item as! Node).path) }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! Node
        let cell = NSTableCellView(), label = NSTextField(labelWithString: node === root ? (node.path.isEmpty ? "/（根目录）" : SessionDirectory.display(node.path)) : String(node.path.split(separator: "/").last!))
        let icon = NSImageView(); icon.image = NSImage(oshellSymbolName: "folder", accessibilityDescription: nil)
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle
        label.textColor = selectable(node.path) ? .labelColor : .disabledControlTextColor
        cell.textField = label; cell.imageView = icon; cell.toolTip = SessionDirectory.display(node.path)
        for view in [icon, label] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16), label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6)])
        return cell
    }
    static func choose(directories: [String], selected: String, excluded: [String] = [], title: String = "选择会话目录", rootDirectory: String = "") -> String? {
        let tree = SessionDirectoryTree(directories: directories, selected: selected, excluded: excluded, rootDirectory: rootDirectory)
        let alert = PopupAlert(); alert.messageText = title
        alert.informativeText = rootDirectory.isEmpty ? "展开目录并选择目标位置；/ 表示根目录。" : "快捷引用统一保存在 /Links 下，请选择目标目录。"
        alert.addButton(withTitle: "选择"); alert.addButton(withTitle: "取消")
        alert.accessoryView = tree; alert.window.initialFirstResponder = tree.outline
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return tree.selectedDirectory
    }
}

/// A non-editable field: directory creation belongs to the session manager.
final class SessionDirectoryPicker: NSButton {
    private var directories = [String]()
    private var rootDirectory = ""
    private(set) var selectedDirectory = ""
    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded; alignment = .left; lineBreakMode = .byTruncatingMiddle
        target = self; action = #selector(choose); setAccessibilityLabel("会话目录")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(directories: [String], selected: String, rootDirectory: String = "") {
        self.rootDirectory = SessionDirectory.normalize(rootDirectory)
        var config = Configuration(profiles: []); config.directories = directories + [selected]
        self.directories = SessionDirectory.all(config); _ = selectDirectory(SessionDirectory.normalize(selected))
    }
    @discardableResult func selectDirectory(_ path: String) -> Bool {
        guard (rootDirectory.isEmpty || SessionDirectory.contains(path, in: rootDirectory)), path.isEmpty || directories.contains(path) else { return false }
        selectedDirectory = path; title = SessionDirectory.display(path) + "  ▾"
        toolTip = "会话分类目录：\(SessionDirectory.display(path))；点击从目录树中选择。"
        setAccessibilityValue(SessionDirectory.display(path)); return true
    }
    @objc private func choose() {
        if let selected = SessionDirectoryTree.choose(directories: directories, selected: selectedDirectory, rootDirectory: rootDirectory) { _ = selectDirectory(selected) }
    }
}
