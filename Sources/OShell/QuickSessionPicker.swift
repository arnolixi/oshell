// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

struct QuickSessionEntry {
    let paneID: UUID?, profileID: UUID
    let title: String, detail: String, searchText: String
}

/// A transient metadata-only palette: never scans terminal output or credentials.
final class QuickSessionPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let entries: [QuickSessionEntry]
    private let searchIndex: [String]
    private(set) var results = [QuickSessionEntry]()
    let search = NSSearchField(), scope = NSPopUpButton(), table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private weak var acceptButton: NSButton?
    private var accept: (() -> Void)?
    private final class Row: NSTableCellView {
        let title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
        override init(frame: NSRect) {
            super.init(frame: frame)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
            for label in [title, detail] { label.lineBreakMode = .byTruncatingMiddle; addSubview(label) }
            textField = title
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            title.frame = NSRect(x: 8, y: 23, width: max(0, bounds.width - 16), height: 18)
            detail.frame = NSRect(x: 8, y: 4, width: max(0, bounds.width - 16), height: 16)
        }
    }
    init(entries: [QuickSessionEntry]) {
        self.entries = entries; searchIndex = entries.map { SessionSearchQuery.normalize($0.searchText) }
        super.init()
        search.placeholderString = "搜索主机名、IP、会话名称、目录或分组"; search.delegate = self
        search.identifier = .init("quickSession.search"); search.setAccessibilityLabel("快速定位会话")
        scope.addItems(withTitles: ["全部", "已打开终端", "已保存"]); scope.target = self; scope.action = #selector(scopeChanged)
        scope.identifier = .init("quickSession.scope")
        let column = NSTableColumn(identifier: .init("session")); column.width = 610; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 46; table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.identifier = .init("quickSession.results"); table.setAccessibilityLabel("会话搜索结果")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        reload()
    }
    private static func display(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(500))
    }
    func reload() {
        let old = selected
        let query = SessionSearchQuery(search.stringValue)
        let matches = entries.indices.filter { index in
            (scope.indexOfSelectedItem == 0 || (scope.indexOfSelectedItem == 1 ? entries[index].paneID != nil : entries[index].paneID == nil)) && query.matches(normalized: searchIndex[index])
        }
        results = matches.prefix(200).map { entries[$0] }
        table.reloadData()
        if !results.isEmpty {
            let selectedIndex = old.flatMap { item in results.firstIndex { $0.paneID == item.paneID && $0.profileID == item.profileID } } ?? 0
            table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            table.scrollRowToVisible(selectedIndex)
        }
        status.stringValue = !query.isValid ? "搜索条件过长，请缩短关键词。" : matches.isEmpty ? "没有匹配的会话。" : matches.count > 200 ? "找到 \(matches.count) 项，显示前 200 项；请增加关键词缩小范围。" : "\(matches.count) 项 · ↑↓ 选择 · 回车打开 · Esc 取消"
        updateButton()
    }
    var selected: QuickSessionEntry? { results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil }
    private func updateButton() {
        acceptButton?.isEnabled = selected != nil
        acceptButton?.title = selected?.paneID != nil ? "切换到会话" : "新建连接"
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    @objc private func scopeChanged() { reload() }
    @objc private func openSelected() { if selected != nil { accept?() } }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButton() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let cell = table.makeView(withIdentifier: .init("quickSession.row"), owner: self) as? Row ?? Row(frame: .zero)
        cell.identifier = .init("quickSession.row"); cell.title.stringValue = Self.display(results[row].title)
        cell.detail.stringValue = Self.display(results[row].detail); cell.toolTip = cell.title.stringValue + "\n" + cell.detail.stringValue
        return cell
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : commandSelector == #selector(NSResponder.moveUp(_:)) ? -1 : 0
        guard delta != 0 else { return false }
        if !results.isEmpty {
            let index = min(results.count - 1, max(0, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index)
        }
        return true
    }
    func run() -> QuickSessionEntry? {
        let alert = PopupAlert(); alert.messageText = "快速切换 / 连接会话"
        alert.informativeText = "已打开终端直接定位；已保存会话会建立新连接，支持 SSH / SFTP / FTP。多个关键词用空格分隔。"
        let button = alert.addButton(withTitle: "打开"); alert.addButton(withTitle: "取消")
        acceptButton = button; accept = { [weak button] in button?.performClick(nil) }; updateButton()
        defer { accept = nil; acceptButton = nil }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 380))
        search.frame = NSRect(x: 0, y: 348, width: 510, height: 26)
        scope.frame = NSRect(x: 520, y: 348, width: 120, height: 26)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 28, width: 640, height: 308))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: 308))
        status.frame = NSRect(x: 0, y: 0, width: 640, height: 22)
        [search, scope, scroll, status].forEach(root.addSubview)
        alert.accessoryView = root; alert.window.initialFirstResponder = search
        return alert.runModal() == .alertFirstButtonReturn ? selected : nil
    }
}
