// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

struct SharedConflictDraft: Codable {
    let base: Configuration
    let local: Configuration
}
enum SharedConflictDrafts {
    static func file(for store: ConfigurationStore) -> URL {
        let root = StorageLocation.localStateDirectory
        let key = PlatformDigest.sha256(Data(store.url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("sync-conflicts").appendingPathComponent(key + ".json")
    }
    static func exists(for store: ConfigurationStore) -> Bool { FileManager.default.fileExists(atPath: file(for: store).path) }
    static func load(for store: ConfigurationStore) throws -> SharedConflictDraft? {
        guard let data = try SharedDataFile.readIfPresent(file(for: store)) else { return nil }
        return try JSONDecoder().decode(SharedConflictDraft.self, from: data)
    }
    static func save(_ draft: SharedConflictDraft, for store: ConfigurationStore) throws {
        let url = file(for: store)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(draft), to: url)
    }
    static func clear(for store: ConfigurationStore) throws {
        let url = file(for: store)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

final class SharedConflictView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private let localText = NSTextView(), remoteText = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let conflicts: [ConfigurationMerge.Conflict]
    private(set) var choices = [String: ConfigurationMerge.Choice]()
    var onReady: ((Bool) -> Void)?
    init(_ conflicts: [ConfigurationMerge.Conflict]) {
        self.conflicts = conflicts
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 390))
        let column = NSTableColumn(identifier: .init("conflict")); column.title = "需要确认的项目"; column.width = 205; table.addTableColumn(column)
        table.rowHeight = 30; table.headerView = NSTableHeaderView(); table.delegate = self; table.dataSource = self
        table.identifier = .init("sync.conflicts"); table.allowsEmptySelection = false
        let list = NSScrollView(frame: NSRect(x: 0, y: 38, width: 214, height: 352)); list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder; addSubview(list)
        for (text, x, title) in [(localText, 226.0, "本机待保存版本"), (remoteText, 526.0, "共享目录版本")] {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12, weight: .semibold); label.frame = NSRect(x: x, y: 369, width: 288, height: 20); addSubview(label)
            let scroll = NSScrollView(frame: NSRect(x: x, y: 76, width: 288, height: 286)); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
            text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.font = .systemFont(ofSize: 12)
            text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
            text.frame = NSRect(x: 0, y: 0, width: 286, height: 286); text.textContainer?.widthTracksTextView = true
            scroll.documentView = text; addSubview(scroll)
        }
        let local = NSButton(title: "保留本机版本", target: self, action: #selector(keepLocal))
        let remote = NSButton(title: "保留共享版本", target: self, action: #selector(keepRemote))
        for (button, x) in [(local, 226.0), (remote, 526.0)] { button.bezelStyle = .rounded; button.frame = NSRect(x: x, y: 39, width: 288, height: 32); addSubview(button) }
        status.frame = NSRect(x: 0, y: 4, width: 810, height: 24); status.font = .systemFont(ofSize: 12); addSubview(status)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfRows(in tableView: NSTableView) -> Int { conflicts.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = conflicts[row]
        let prefix = choices[item.key].map { $0 == .local ? "[本机] " : "[共享] " } ?? "[待选] "
        let label = NSTextField(labelWithString: prefix + item.title); label.lineBreakMode = .byTruncatingTail; label.toolTip = item.title
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refresh() }
    private func refresh() {
        if conflicts.indices.contains(table.selectedRow) {
            localText.string = conflicts[table.selectedRow].localDescription; remoteText.string = conflicts[table.selectedRow].remoteDescription
            localText.scrollRangeToVisible(NSRange(location: 0, length: 0)); remoteText.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        status.stringValue = "已选择 \(choices.count) / \(conflicts.count) 项；全部选择后才能确认保存。"
        onReady?(choices.count == conflicts.count)
    }
    @objc private func keepLocal() { choose(.local) }
    @objc private func keepRemote() { choose(.remote) }
    private func choose(_ choice: ConfigurationMerge.Choice) {
        guard conflicts.indices.contains(table.selectedRow) else { return }
        choices[conflicts[table.selectedRow].key] = choice
        let index = conflicts.firstIndex { choices[$0.key] == nil } ?? table.selectedRow
        table.reloadData(); table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); refresh()
    }
}

extension WorkspaceController {
    /// The shared snapshot is checked again on write; no choice is applied to a newer remote version.
    func resolveSharedDraft(_ draft: SharedConflictDraft) throws -> Configuration? {
        try SharedConflictDrafts.save(draft, for: store)
        let snapshot = try store.sharedSnapshot()
        let plan = try ConfigurationMerge(base: draft.base, local: draft.local, remote: snapshot.configuration)
        var choices = [String: ConfigurationMerge.Choice]()
        if !plan.conflicts.isEmpty {
            let alert = PopupAlert(); alert.messageText = "选择要保留的会话配置"
            alert.informativeText = "不同项目的修改会自动合并。以下项目两边都发生了变化，请逐项确认；密码内容不会展示。稍后处理或按 Esc 将保留本机草稿。"
            alert.addButton(withTitle: "确认保存"); alert.addButton(withTitle: "稍后处理")
            let view = SharedConflictView(plan.conflicts); alert.accessoryView = view
            let save = alert.buttons[0]; save.isEnabled = false
            view.onReady = { [weak save] in save?.isEnabled = $0 }
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            choices = view.choices
        }
        let resolved = try plan.resolve(choices)
        guard !appUpdater.isBusy || resolved.preferences.updateRepository == configuration.preferences.updateRepository else { throw ModelError.invalid("更新正在进行，请完成后再处理同步冲突。本机草稿已保留。") }
        if requiresSharingProtection { try SharingProtection.require(resolved) }
        let ids = Set(ConfigurationCredentials.profiles(in: resolved).compactMap { $0.encryptedPassword?.localKeyID })
        guard ids.count <= 1 else { throw ModelError.invalid("合并后的密码使用不同本机密钥，未保存；请先确认密钥同步完成。") }
        if let id = ids.first { _ = try LocalCredentialStore(directory: store.url.deletingLastPathComponent()).load(expectedID: id, repairPermissions: true) }
        do { try store.saveResolved(resolved, expected: snapshot.fingerprint) }
        catch is SharedConfigurationConflict { throw ModelError.invalid("确认期间共享版本再次变化，未覆盖数据。本机草稿已保留，请重新处理同步冲突。") }
        try? SharedConflictDrafts.clear(for: store)
        return resolved
    }
    @objc func resolvePendingSharedConflicts() {
        do {
            guard let draft = try SharedConflictDrafts.load(for: store) else { Dialogs.message("没有待处理的同步冲突。"); return }
            guard let resolved = try resolveSharedDraft(draft) else { return }
            PasswordVault.shared.acceptSharedConfiguration(resolved)
            acceptSavedConfiguration(resolved, applyPreferences: true)
        } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc func discardPendingSharedConflicts() {
        guard SharedConflictDrafts.exists(for: store), Dialogs.confirm("放弃本机同步草稿？", text: "仅删除本机尚未保存的冲突草稿，共享数据保持不变。", action: "放弃草稿") else { return }
        do { try SharedConflictDrafts.clear(for: store); reloadSharedConfiguration() }
        catch { Dialogs.message(error.localizedDescription) }
    }
}
