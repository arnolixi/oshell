// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class SessionManager: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private final class ListCell: NSTableCellView {
        let label = NSTextField(labelWithString: "")
        let icon = NSImageView()
        init(column: String) {
            super.init(frame: .zero)
            identifier = NSUserInterfaceItemIdentifier(column)
            textField = label
            label.font = .systemFont(ofSize: 13)
            label.maximumNumberOfLines = 1; label.cell?.usesSingleLineMode = true
            label.lineBreakMode = ["host", "directory"].contains(column) ? .byTruncatingMiddle : .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
            ])
            if column == "name" {
                imageView = icon; icon.imageScaling = .scaleProportionallyDown
                icon.translatesAutoresizingMaskIntoConstraints = false; addSubview(icon)
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                    icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8)
                ])
            } else { label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6).isActive = true }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    private final class EmptyLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private final class ContextTable: NSTableView {
        var makeContextMenu: ((Int) -> NSMenu?)?
        var navigateParent: ((Int) -> Bool)?
        var activateSelection: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control]).isEmpty { activateSelection?(); return }
            super.keyDown(with: event)
        }
        private var consumedParentClick = false
        override func mouseDown(with event: NSEvent) {
            // A double click on ../ must not activate a different row after
            // the first click has already navigated and rebuilt the listing.
            if event.clickCount > 1 && consumedParentClick { return }
            consumedParentClick = false
            if event.modifierFlags.intersection([.command, .shift]).isEmpty,
               navigateParent?(row(at: convert(event.locationInWindow, from: nil))) == true {
                consumedParentClick = true
                return
            }
            super.mouseDown(with: event)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            makeContextMenu?(row(at: convert(event.locationInWindow, from: nil)))
        }
    }
    private enum Row { case parent, directory(String), session(SessionProfile) }
    private weak var workspace: WorkspaceController?
    private let table = ContextTable(), search = NSSearchField(), path = NSTextField(labelWithString: "所有会话")
    private var rows = [Row]()
    private let searchScope = NSPopUpButton()
    private let resultStatus = NSTextField(labelWithString: "")
    private let emptyLabel = EmptyLabel(labelWithString: "没有匹配的会话或目录\n可调整关键词、协议或搜索范围")
    private let connectButton = NSButton()
    private var sourceProfiles = [SessionProfile](), sortedProfiles = [SessionProfile]()
    private var sourceDirectories = [String](), allDirectories = [String]()
    private var metadata = [UUID: String](), directoryMetadata = [String: String]()
    private var currentQuery = SessionSearchQuery("")
    private func key(_ row: Row) -> String {
        switch row { case .parent: return "parent"; case .directory(let path): return "directory:" + path; case .session(let profile): return profile.id.uuidString }
    }
    let kindFilter = NSPopUpButton()
    private var filesOnly = false
    private var fileSelection: ((SessionProfile) -> Void)?
    private(set) var currentDirectory = ""
    var selectedProfiles: [SessionProfile] {
        table.selectedRowIndexes.compactMap { index in
            guard rows.indices.contains(index), case .session(let profile) = rows[index] else { return nil }; return profile
        }
    }
    var selectedProfile: SessionProfile? {
        guard table.selectedRowIndexes.count == 1, rows.indices.contains(table.selectedRow), case .session(let profile) = rows[table.selectedRow] else { return nil }; return profile
    }
    init(workspace: WorkspaceController) {
        self.workspace = workspace
        let window = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "会话管理"; window.minSize = NSSize(width: 720, height: 400); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.onFind = { [weak self] in self?.focusSearch() }; window.center(); build(); reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() { filesOnly = false; fileSelection = nil; table.allowsMultipleSelection = true; window?.title = "会话管理"; reload(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    func showFiles(selection: @escaping (SessionProfile) -> Void) {
        filesOnly = true; fileSelection = selection; table.deselectAll(nil); table.allowsMultipleSelection = false; kindFilter.selectItem(at: 0)
        window?.title = "会话管理 · 选择文件会话"; reload(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func showPreservingMode() { reload(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    private func clearFileSelection() { fileSelection = nil; filesOnly = false; table.allowsMultipleSelection = true; window?.title = "会话管理" }
    func windowWillClose(_ notification: Notification) { clearFileSelection() }
    var visibleProfiles: [SessionProfile] { rows.compactMap { if case .session(let profile) = $0 { return profile }; return nil } }
    @objc private func changeKindFilter() { reload() }
    private func button(_ title: String, _ action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button }
    private func build() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "名称、IP、用户名、端口；空格分隔关键词"; search.delegate = self
        search.toolTip = "搜索名称、主机/IP、用户名、端口、协议和目录。多个关键词需同时匹配，例如：生产 root 2222。⌘F 聚焦；↓ 进入结果；回车打开选中项。"
        search.setAccessibilityLabel("会话搜索")
        search.target = self; search.action = #selector(searchSubmitted)
        search.sendsSearchStringImmediately = false
        searchScope.addItems(withTitles: ["当前目录及子目录", "全部目录"])
        searchScope.setAccessibilityLabel("会话搜索范围"); searchScope.toolTip = "范围用于关键词搜索；清空后恢复当前目录浏览。"
        searchScope.target = self; searchScope.action = #selector(changeKindFilter)
        searchScope.widthAnchor.constraint(equalToConstant: 156).isActive = true
        kindFilter.addItems(withTitles: ["全部协议", "SSH", "SFTP", "FTP", "本地"]); kindFilter.target = self; kindFilter.action = #selector(changeKindFilter)
        kindFilter.setAccessibilityLabel("会话协议分类"); kindFilter.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let navigation = NSStackView(views: [button("所有会话", #selector(root)), button("上一级", #selector(up)), path, NSView()]); navigation.spacing = 8
        let filters = NSStackView(views: [search, kindFilter, searchScope]); filters.spacing = 8
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (id, title, width, minimum) in [("name", "名称", 210.0, 160.0), ("protocol", "协议", 64.0, 56.0), ("host", "主机", 190.0, 140.0), ("user", "用户名", 100.0, 80.0), ("port", "端口", 60.0, 56.0), ("directory", "目录", 160.0, 100.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.minWidth = minimum; column.width = width
            column.resizingMask = [.autoresizingMask, .userResizingMask]
            column.headerCell.font = .systemFont(ofSize: 12, weight: .medium)
            table.addTableColumn(column)
        }
        // Use explicit table metrics: automatic style adds OS-dependent insets,
        // and a bare NSTextField is stretched to row height instead of centered.
        if #available(macOS 11, *) { table.style = .plain }; table.rowSizeStyle = .custom; table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true; table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(openSelection)
        table.activateSelection = { [weak self] in self?.activateSelection() }
        table.makeContextMenu = { [weak self] row in self?.contextMenu(for: row) }
        table.navigateParent = { [weak self] row in
            guard let self, self.rows.indices.contains(row), case .parent = self.rows[row] else { return false }
            self.up(); return true
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        resultStatus.font = .systemFont(ofSize: 11); resultStatus.textColor = .secondaryLabelColor
        resultStatus.lineBreakMode = .byTruncatingTail; resultStatus.setAccessibilityLabel("会话搜索结果")
        resultStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resultStatus.toolTip = "⌘ 单击多选，⇧ 单击连续选择，点击连接批量打开；单击 ../ 返回上级；右键管理；Esc 关闭。"
        connectButton.title = "连接"; connectButton.target = self; connectButton.action = #selector(activateSelection); connectButton.bezelStyle = .rounded
        let bottom = NSStackView(views: [resultStatus, NSView(), connectButton, button("关闭", #selector(hide))]); bottom.spacing = 10
        emptyLabel.alignment = .center; emptyLabel.maximumNumberOfLines = 2; emptyLabel.textColor = .secondaryLabelColor; emptyLabel.font = .systemFont(ofSize: 13)
        [navigation, filters, scroll, bottom, emptyLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), navigation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), navigation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            filters.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 8), filters.leadingAnchor.constraint(equalTo: navigation.leadingAnchor), filters.trailingAnchor.constraint(equalTo: navigation.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: navigation.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: navigation.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor), emptyLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20), emptyLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            bottom.leadingAnchor.constraint(equalTo: navigation.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: navigation.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
    }

    func contextMenu(for row: Int) -> NSMenu {
        // Target the row under the pointer, not an older selection. Blank-space
        // clicks must never expose destructive actions for that older selection.
        if rows.indices.contains(row) {
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        else { table.deselectAll(nil) }
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled
        }
        if table.selectedRowIndexes.count > 1 {
            add("连接（\(selectedProfiles.count)）", #selector(connect), enabled: !selectedProfiles.isEmpty)
            return menu
        }
        if rows.indices.contains(row) {
            switch rows[row] {
            case .parent:
                add("上一级", #selector(up))
            case .directory:
                add("打开目录", #selector(openDirectory))
                add("重命名…", #selector(edit))
            case .session(let profile):
                add("连接", #selector(connect), enabled: !filesOnly || profile.kind != .local)
                if profile.kind.usesSSH { add("打开 SFTP 文件", #selector(openFiles)) }
                if profile.kind == .sftp { add("打开 SSH 终端", #selector(openTerminal)) }
                add("属性…", #selector(edit), enabled: profile.kind != .local)
                add("复制会话", #selector(duplicateSession), enabled: profile.kind != .local)
            }
            if case .parent = rows[row] { /* Navigation only; never mutate this row. */ }
            else {
                add("移动到…", #selector(move))
                add("删除…", #selector(remove))
            }
            menu.addItem(.separator())
        }
        add("新建 SSH 会话…", #selector(newSession))
        add("新建 SFTP 会话…", #selector(newSFTP))
        add("新建 FTP 会话…", #selector(newFTP))
        add("新建目录…", #selector(newDirectory))
        add("会话默认属性…", #selector(showSessionDefaults))
        menu.addItem(.separator())
        if rows.indices.contains(row) {
            switch rows[row] {
            case .session: add("导出此会话…", #selector(exportSelection))
            case .directory: add("导出此目录…", #selector(exportSelection))
            case .parent: break
            }
        }
        add("导出全部会话…", #selector(exportAll))
        add("导入会话到当前目录…", #selector(importSessions))
        return menu
    }
    @objc private func exportSelection() {
        guard let workspace, rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] {
        case .parent: return
        case .session(let profile): SessionTransfer.export(profiles: [profile], directories: profile.group.isEmpty ? [] : [profile.group])
        case .directory(let directory):
            SessionTransfer.export(profiles: workspace.configuration.profiles.filter { SessionDirectory.contains($0.group, in: directory) },
                                   directories: SessionDirectory.all(workspace.configuration).filter { SessionDirectory.contains($0, in: directory) })
        }
    }
    @objc func exportAll() {
        guard let workspace else { return }
        SessionTransfer.export(profiles: workspace.configuration.profiles, directories: SessionDirectory.all(workspace.configuration))
    }
    @objc func importSessions() {
        guard let workspace else { return }
        SessionTransfer.importSessions(workspace: workspace, directory: currentDirectory); reload()
    }
    func reload(select id: UUID? = nil) {
        guard let configuration = workspace?.configuration else { return }
        let oldKeys = id.map { Set([$0.uuidString]) } ?? Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? key(rows[$0]) : nil })
        if sourceProfiles != configuration.profiles || sourceDirectories != configuration.directories || metadata.count != configuration.profiles.count {
            sourceProfiles = configuration.profiles; sourceDirectories = configuration.directories
            sortedProfiles = sourceProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            allDirectories = SessionDirectory.all(configuration)
            metadata = Dictionary(sourceProfiles.map { ($0.id, SessionSearchQuery.metadata($0)) }, uniquingKeysWith: { _, next in next })
            directoryMetadata = Dictionary(uniqueKeysWithValues: allDirectories.map { ($0, SessionSearchQuery.normalize(SessionDirectory.display($0))) })
        }
        if !currentDirectory.isEmpty && !allDirectories.contains(currentDirectory) { currentDirectory = "" }
        currentQuery = SessionSearchQuery(search.stringValue)
        let searching = !currentQuery.isEmpty
        let global = searching && searchScope.indexOfSelectedItem == 1
        func inScope(_ directory: String) -> Bool { global || currentDirectory.isEmpty || SessionDirectory.contains(directory, in: currentDirectory) }
        let directoryRows = allDirectories.filter {
            searching ? ($0 != currentDirectory && inScope($0) && currentQuery.matches(normalized: directoryMetadata[$0] ?? "")) : SessionDirectory.parent($0) == currentDirectory
        }
        let kinds: [SessionKind?] = [nil, .ssh, .sftp, .ftp, .local]
        let kind = kinds.indices.contains(kindFilter.indexOfSelectedItem) ? kinds[kindFilter.indexOfSelectedItem] : nil
        let profiles = sortedProfiles.filter {
            (!filesOnly || $0.kind != .local) && (kind == nil || $0.kind == kind)
            && (searching ? inScope($0.group) : $0.group == currentDirectory)
            && currentQuery.matches(normalized: metadata[$0.id] ?? "")
        }
        rows = currentDirectory.isEmpty ? [] : [.parent]
        rows += directoryRows.map(Row.directory); rows += profiles.map(Row.session)
        path.stringValue = SessionDirectory.display(currentDirectory)
        path.toolTip = path.stringValue
        table.reloadData(); table.deselectAll(nil)
        let retained = IndexSet(rows.indices.filter { oldKeys.contains(key(rows[$0])) && !(searching && key(rows[$0]) == "parent") })
        if !retained.isEmpty { table.selectRowIndexes(retained, byExtendingSelection: false) }
        else if searching, let index = rows.firstIndex(where: { if case .parent = $0 { return false }; return true }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        resultStatus.stringValue = currentQuery.isValid ? "\(profiles.count) 个会话 · \(directoryRows.count) 个目录" + (searching ? (global ? " · 全部目录" : " · 当前目录及子目录") : "") : "搜索内容过长：最多 4 KB / 32 个关键词"
        resultStatus.textColor = currentQuery.isValid ? .secondaryLabelColor : .systemRed
        emptyLabel.stringValue = searching ? "没有匹配的会话或目录\n可调整关键词、协议或搜索范围" : "当前目录没有可显示的会话或目录\n右键可以新建会话或目录"
        emptyLabel.isHidden = !profiles.isEmpty || !directoryRows.isEmpty
        searchScope.isEnabled = searching; kindFilter.item(at: 4)?.isEnabled = !filesOnly
        updateConnectButton()
    }
    func focusSearch() { window?.makeFirstResponder(search); search.selectText(nil) }
    func tableViewSelectionDidChange(_ notification: Notification) { updateConnectButton() }
    private func updateConnectButton() {
        let count = selectedProfiles.count
        connectButton.isEnabled = count > 0 || (table.selectedRowIndexes.count == 1 && rows.indices.contains(table.selectedRow))
        connectButton.title = count > 1 ? "连接（\(count)）" : (count == 1 || !connectButton.isEnabled ? "连接" : "打开")
    }
    @objc private func activateSelection() {
        if !selectedProfiles.isEmpty { connect(); return }
        guard table.selectedRowIndexes.count == 1, rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] { case .parent: up(); case .directory: openDirectory(); case .session: connect() }
    }
    @objc private func searchSubmitted() {
        if let editor = search.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        // NSSearchField can also send its action when the clear button is clicked.
        // Editing must never connect to a server; Return is handled explicitly below.
        reload()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { reload(); activateSelection(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) {
            if table.selectedRow < 0, let index = rows.firstIndex(where: { if case .parent = $0 { return false }; return true }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }; window?.makeFirstResponder(table); return true
        }
        return false
    }
    func reveal(_ profile: SessionProfile) { kindFilter.selectItem(at: 0); currentDirectory = profile.group; search.stringValue = ""; reload(select: profile.id) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let text: String
        var symbol: String? = nil
        switch rows[row] {
        case .parent: text = identifier.rawValue == "name" ? "../" : ""; symbol = "arrow.turn.up.left"
        case .directory(let directory):
            switch identifier.rawValue {
            case "name": text = String(directory.split(separator: "/").last ?? "")
            case "directory": text = currentQuery.isEmpty ? "" : SessionDirectory.display(SessionDirectory.parent(directory))
            default: text = ""
            }
            symbol = "folder"
        case .session(let profile):
            symbol = profile.kind.isFileSession ? "folder.badge.gearshape" : "terminal"
            switch tableColumn?.identifier.rawValue {
            case "name": text = profile.name
            case "protocol": text = profile.kind.title
            case "host": text = profile.kind == .local ? "本地终端" : profile.host
            case "user": text = profile.username
            case "port": text = profile.kind == .local ? "—" : String(profile.port)
            default: text = SessionDirectory.display(profile.group)
            }
        }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ListCell ?? ListCell(column: identifier.rawValue)
        let styled = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let ns = text as NSString
        for term in currentQuery.terms {
            var range = NSRange(location: 0, length: ns.length)
            while range.length > 0 {
                let found = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: range)
                if found.location == NSNotFound || found.length == 0 { break }
                styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: found)
                let end = NSMaxRange(found); range = NSRange(location: end, length: ns.length - end)
            }
        }
        cell.label.attributedStringValue = styled
        cell.icon.image = identifier.rawValue == "name" ? symbol.flatMap { NSImage(oshellSymbolName: $0, accessibilityDescription: nil) } : nil
        if case .parent = rows[row] { cell.toolTip = "点击返回上一级目录" } else { cell.toolTip = text }
        return cell
    }
    func controlTextDidChange(_ obj: Notification) {
        if let editor = search.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        reload()
    }
    private func navigate(to directory: String) {
        currentDirectory = directory; search.stringValue = ""; table.deselectAll(nil); reload()
        if !rows.isEmpty { table.scrollRowToVisible(0) }
    }
    @objc private func root() { navigate(to: "") }
    @objc private func up() { navigate(to: SessionDirectory.parent(currentDirectory)) }
    @objc private func openSelection() {
        guard rows.indices.contains(table.clickedRow) else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        activateSelection()
    }
    @objc private func openDirectory() {
        guard rows.indices.contains(table.selectedRow), case .directory(let directory) = rows[table.selectedRow] else { return }
        navigate(to: directory)
    }
    @objc private func connect() {
        let profiles = selectedProfiles
        guard !profiles.isEmpty else { return }
        if filesOnly {
            guard profiles.count == 1, let profile = profiles.first, profile.kind != .local else { return }
            let selection = fileSelection; clearFileSelection(); window?.orderOut(nil); selection?(profile)
        } else {
            window?.orderOut(nil)
            for profile in profiles { workspace?.open(profile) }
            if profiles.contains(where: { !$0.kind.isFileSession }) { workspace?.show() }
        }
    }
    @objc private func openFiles() {
        guard let profile = selectedProfile, profile.kind.usesSSH else { return }
        window?.orderOut(nil)
        if let selection = fileSelection { clearFileSelection(); selection(profile) }
        else { workspace?.openFiles(for: profile, directory: profile.initialDirectory) }
    }
    @objc private func openTerminal() {
        guard var profile = selectedProfile, profile.kind.usesSSH else { return }
        profile.kind = .ssh; clearFileSelection(); window?.orderOut(nil); workspace?.open(profile); workspace?.show()
    }
    @objc private func hide() { clearFileSelection(); window?.orderOut(nil) }
    @objc private func newSession() { workspace?.createSession(kind: .ssh) }
    @objc private func newSFTP() { workspace?.createSession(kind: .sftp) }
    @objc private func newFTP() { workspace?.createSession(kind: .ftp) }
    @objc private func showSessionDefaults() { workspace?.showSessionDefaults() }
    @objc private func duplicateSession() {
        guard let profile = selectedProfile, let copy = workspace?.duplicateSavedSession(profile.id) else { return }
        reveal(copy)
    }
    private func askPath(_ title: String, value: String, message: String, relativeTo base: String) -> String? {
        let alert = PopupAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let input = NSTextField(string: SessionDirectory.display(value)); input.placeholderString = "/生产/机房"; input.identifier = .init("session.directory.path"); input.frame = NSRect(x: 0, y: 0, width: 420, height: 26); alert.accessoryView = input; alert.window.initialFirstResponder = input
        while alert.runModal() == .alertFirstButtonReturn {
            do { return try SessionDirectory.resolvePath(input.stringValue, relativeTo: base) }
            catch { Dialogs.message(error.localizedDescription) }
        }
        return nil
    }
    @objc private func newDirectory() {
        guard let workspace, let path = askPath("新建目录", value: currentDirectory.isEmpty ? "新目录" : currentDirectory + "/新目录", message: "使用 Linux 格式，例如 /生产/机房；相对路径基于当前目录，支持 . 和 ..。", relativeTo: currentDirectory), !path.isEmpty else { return }
        var config = workspace.configuration
        guard !SessionDirectory.all(config).contains(path) else { Dialogs.message("目录已存在。"); return }
        config.directories.append(path)
        if workspace.saveConfiguration(config) { currentDirectory = SessionDirectory.parent(path); reload() }
    }
    @objc private func edit() {
        guard rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] {
        case .parent: return
        case .session: workspace?.editSession()
        case .directory(let old):
            guard let next = askPath("重命名 / 移动目录", value: old, message: "填写新路径，例如 /生产/机房；相对路径基于原父目录。子目录和会话会一起移动。", relativeTo: SessionDirectory.parent(old)) else { return }; renameDirectory(old, to: next)
        }
    }
    private func renameDirectory(_ old: String, to next: String) {
        guard let workspace, !next.isEmpty, old != next else { return }
        var config = workspace.configuration
        guard !SessionDirectory.contains(next, in: old), !SessionDirectory.all(config).contains(next) else { Dialogs.message("目标目录已存在，或位于当前目录内部。"); return }
        func remap(_ path: String) -> String { SessionDirectory.contains(path, in: old) ? next + String(path.dropFirst(old.count)) : path }
        config.directories = SessionDirectory.all(config).map(remap)
        for index in config.profiles.indices { config.profiles[index].group = remap(config.profiles[index].group) }
        if workspace.saveConfiguration(config) { reload() }
    }
    @objc private func move() {
        guard let workspace, rows.indices.contains(table.selectedRow) else { return }
        if case .parent = rows[table.selectedRow] { return }
        let origin: String
        switch rows[table.selectedRow] { case .session(let profile): origin = profile.group; case .directory(let path): origin = SessionDirectory.parent(path); case .parent: return }
        guard let destination = askPath("移动到目录", value: origin, message: "填写目标路径；/ 或留空表示根目录，相对路径基于当前所属目录。不存在的目录将自动创建。", relativeTo: origin) else { return }
        switch rows[table.selectedRow] {
        case .parent: return
        case .directory(let old): renameDirectory(old, to: [destination, String(old.split(separator: "/").last!)].filter { !$0.isEmpty }.joined(separator: "/"))
        case .session(let profile):
            var config = workspace.configuration; guard let index = config.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
            config.profiles[index].group = destination
            if !destination.isEmpty { config.directories.append(destination) }
            if workspace.saveConfiguration(config) { reload() }
        }
    }
    @objc private func remove() {
        guard let workspace, rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] {
        case .parent: return
        case .session: workspace.deleteSession()
        case .directory(let directory):
            var config = workspace.configuration
            guard !config.profiles.contains(where: { SessionDirectory.contains($0.group, in: directory) }), !SessionDirectory.all(config).contains(where: { $0.hasPrefix(directory + "/") }) else { Dialogs.message("目录非空，请先移动或删除其中的会话和子目录。"); return }
            guard Dialogs.confirm("删除空目录“\(directory)”？", text: "此操作不会关闭任何已打开的连接。", action: "删除") else { return }
            config.directories.removeAll { $0 == directory }; _ = workspace.saveConfiguration(config); reload()
        }
    }
}
