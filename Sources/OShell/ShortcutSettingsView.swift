// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class ShortcutRecorder: NSButton {
    static weak var active: ShortcutRecorder?
    private(set) var isRecording = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    var onShortcut: ((KeyboardShortcut) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { if isRecording { stopRecording() } else { startRecording() } }
    @objc func toggleRecording() { if isRecording { stopRecording() } else { startRecording() } }
    func startRecording() {
        stopRecording(); guard let hostWindow = window else { return }; Self.active = self; isRecording = true; title = "按下组合键，Esc 结束录入"
        hostWindow.makeFirstResponder(self)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: hostWindow, queue: .main) { [weak self] _ in self?.stopRecording() }
        // App-local only; recording must not trigger menus or type into a terminal.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.type == .leftMouseDown {
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.stopRecording() }
                return event
            }
            guard event.window === self.window || (event.window == nil && NSApp.keyWindow === self.window) else { return event }
            if event.keyCode == 53 && event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty { self.stopRecording(); return nil }
            if !event.isARepeat { let shortcut = KeyboardShortcut(event: event); self.title = "录入中：" + shortcut.display + "（Esc 结束）"; self.onShortcut?(shortcut) }
            return nil
        }
    }
    func stopRecording() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; isRecording = false; if Self.active === self { Self.active = nil }; title = "录入快捷键"
    }
    override func becomeFirstResponder() -> Bool { true }
    override func keyDown(with event: NSEvent) { if !isRecording { startRecording() } }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

final class ShortcutSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView(), keyPopup = NSPopUpButton(), recorder = ShortcutRecorder()
    let assignButton = NSButton(), status = NSTextField(wrappingLabelWithString: "")
    private let function = NSTextField(labelWithString: "")
    private var modifiers = [(Int, NSButton)]()
    private(set) var settings: KeyboardShortcuts
    private let original: KeyboardShortcuts
    private var system: ShortcutSystemConflicts
    private let systemProvider: () -> ShortcutSystemConflicts
    private(set) var selectedAction: ShortcutAction = .sessionManager
    private var isReloading = false
    init(settings: KeyboardShortcuts, systemProvider: @escaping () -> ShortcutSystemConflicts = ShortcutSystemConflicts.load) {
        self.settings = settings; original = settings; self.systemProvider = systemProvider; system = systemProvider()
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        let info = NSTextField(wrappingLabelWithString: "选择功能，再录入组合键；也可用修饰键和按键列表指定。点击“设为此快捷键”暂存，最后点击设置窗口的“应用”生效。")
        info.font = .systemFont(ofSize: 12)
        for (name, title, width) in [("action","功能",240.0),("binding","快捷键",180.0),("state","检测结果",330.0)] {
            let column = NSTableColumn(identifier: .init(name)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.headerView = NSTableHeaderView(); table.rowHeight = 27; table.usesAlternatingRowBackgroundColors = true
        table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = false
        table.identifier = .init("settings.shortcuts.actions")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        function.font = .systemFont(ofSize: 12, weight: .semibold)
        for (bit, title) in [(KeyboardShortcut.command,"⌘ Command"),(KeyboardShortcut.option,"⌥ Option"),(KeyboardShortcut.control,"⌃ Control"),(KeyboardShortcut.shift,"⇧ Shift")] {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(candidateChanged)); modifiers.append((bit,button))
        }
        keyPopup.addItems(withTitles: ShortcutKey.all.map(\.label)); keyPopup.target = self; keyPopup.action = #selector(candidateChanged)
        keyPopup.identifier = .init("settings.shortcuts.key"); keyPopup.widthAnchor.constraint(equalToConstant: 102).isActive = true
        let combination = NSStackView(views: modifiers.map { $0.1 } + [keyPopup]); combination.spacing = 12
        recorder.target = recorder; recorder.action = #selector(ShortcutRecorder.toggleRecording); recorder.bezelStyle = .rounded; recorder.title = "录入快捷键"; recorder.setAccessibilityLabel("录入快捷键")
        recorder.onShortcut = { [weak self] shortcut in self?.setCandidate(shortcut) }
        func button(_ title: String, _ action: Selector) -> NSButton { let value = NSButton(title: title, target: self, action: action); value.bezelStyle = .rounded; return value }
        assignButton.title = "设为此快捷键"; assignButton.target = self; assignButton.action = #selector(assign); assignButton.bezelStyle = .rounded
        let operations = NSStackView(views: [recorder, assignButton, button("清除", #selector(clear)), button("恢复所选默认", #selector(restoreSelected)), button("恢复全部默认", #selector(restoreAll))]); operations.spacing = 8
        let refresh = button("重新检查系统冲突", #selector(recheckSystem))
        let help = NSTextField(wrappingLabelWithString: "快捷键以本页为准，按物理键位绑定。已启用的 macOS 系统快捷键及 OShell 内部重复绑定会阻止指定；第三方全局快捷键无法完整检测。自定义组合优先于终端输入，普通 Esc 和纯文字键保留给输入。")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11); status.identifier = .init("settings.shortcuts.status")
        for view in [info, scroll, function, combination, operations, status, refresh, help] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            info.topAnchor.constraint(equalTo: topAnchor, constant: 16), info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: info.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: info.trailingAnchor), scroll.heightAnchor.constraint(equalToConstant: 235),
            function.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10), function.leadingAnchor.constraint(equalTo: info.leadingAnchor),
            combination.topAnchor.constraint(equalTo: function.bottomAnchor, constant: 8), combination.leadingAnchor.constraint(equalTo: info.leadingAnchor),
            operations.topAnchor.constraint(equalTo: combination.bottomAnchor, constant: 8), operations.leadingAnchor.constraint(equalTo: info.leadingAnchor), operations.trailingAnchor.constraint(lessThanOrEqualTo: info.trailingAnchor),
            status.topAnchor.constraint(equalTo: operations.bottomAnchor, constant: 8), status.leadingAnchor.constraint(equalTo: info.leadingAnchor), status.trailingAnchor.constraint(equalTo: info.trailingAnchor),
            refresh.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6), refresh.leadingAnchor.constraint(equalTo: info.leadingAnchor),
            help.topAnchor.constraint(equalTo: refresh.bottomAnchor, constant: 6), help.leadingAnchor.constraint(equalTo: info.leadingAnchor), help.trailingAnchor.constraint(equalTo: info.trailingAnchor), help.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])
        selectAction(.sessionManager)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfRows(in tableView: NSTableView) -> Int { ShortcutAction.allCases.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = ShortcutAction.allCases[row], bindings = settings.bindings(for: action)
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "action": text = action.title
        case "binding": text = bindings.isEmpty ? "未设置" : bindings.map(\.display).joined(separator: " / ")
        default:
            text = bindings.compactMap { issue($0, action: action) }.first ?? (bindings.isEmpty ? "—" : (system.readable ? "未发现已知冲突" : "系统快捷键读取失败"))
        }
        let cell = NSTableCellView(), label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label); cell.textField = label; cell.toolTip = text
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, ShortcutAction.allCases.indices.contains(table.selectedRow) else { return }
        selectedAction = ShortcutAction.allCases[table.selectedRow]; loadSelected()
    }
    private func reloadRows() {
        isReloading = true; defer { isReloading = false }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: ShortcutAction.allCases.firstIndex(of: selectedAction)!), byExtendingSelection: false)
    }
    func selectAction(_ action: ShortcutAction) { selectedAction = action; table.selectRowIndexes(IndexSet(integer: ShortcutAction.allCases.firstIndex(of: action)!), byExtendingSelection: false); loadSelected() }
    private func loadSelected() {
        recorder.stopRecording(); function.stringValue = "当前功能：" + selectedAction.title
        setCandidate(settings.bindings(for: selectedAction).first ?? .init(0, KeyboardShortcut.command))
    }
    func setCandidate(_ shortcut: KeyboardShortcut) {
        for (bit, button) in modifiers { button.state = shortcut.modifiers & bit == 0 ? .off : .on }
        keyPopup.selectItem(at: ShortcutKey.all.firstIndex { $0.code == shortcut.keyCode } ?? -1)
        updateCandidateStatus()
    }
    private var candidate: KeyboardShortcut? {
        guard ShortcutKey.all.indices.contains(keyPopup.indexOfSelectedItem) else { return nil }
        return .init(ShortcutKey.all[keyPopup.indexOfSelectedItem].code, modifiers.filter { $0.1.state == .on }.reduce(0) { $0 | $1.0 })
    }
    private func issue(_ shortcut: KeyboardShortcut, action: ShortcutAction) -> String? {
        if !shortcut.isValid { return "请使用 ⌘ / ⌥ / ⌃ 组合键，或 F1–F20。" }
        if let other = settings.conflict(shortcut, excluding: action) { return "与 OShell 功能“" + other.title + "”冲突" }
        return system.conflict(shortcut)
    }
    @objc private func candidateChanged() { recorder.stopRecording(); updateCandidateStatus() }
    private func updateCandidateStatus() {
        let problem = candidate.flatMap { issue($0, action: selectedAction) } ?? (candidate == nil ? "此按键暂不支持，请从列表选择。" : nil)
        assignButton.isEnabled = problem == nil
        status.stringValue = problem ?? (system.readable ? "未发现已知冲突；第三方全局快捷键仍需自行确认。" : "无法读取系统快捷键；仅完成 OShell 内部检查，请在系统设置中核对。")
        status.textColor = problem == nil ? .secondaryLabelColor : .systemRed
    }
    @objc func assign() {
        guard let candidate, issue(candidate, action: selectedAction) == nil else { return }
        recorder.stopRecording(); settings.overrides[selectedAction.rawValue] = .init(candidate); reloadRows(); updateCandidateStatus()
    }
    @objc func clear() { recorder.stopRecording(); settings.overrides[selectedAction.rawValue] = .init(nil); reloadRows(); updateCandidateStatus() }
    @objc func restoreSelected() { settings.overrides.removeValue(forKey: selectedAction.rawValue); reloadRows(); loadSelected() }
    @objc func restoreAll() { settings = KeyboardShortcuts(); reloadRows(); loadSelected() }
    @objc func recheckSystem() { system = systemProvider(); reloadRows(); updateCandidateStatus() }
    func values() throws -> KeyboardShortcuts {
        recorder.stopRecording(); try settings.validate()
        if settings != original {
            recheckSystem()
            for action in ShortcutAction.allCases where settings.bindings(for: action) != original.bindings(for: action) {
                for shortcut in settings.bindings(for: action) {
                    if let conflict = system.conflict(shortcut) { throw ModelError.invalid("“\(action.title)”的 \(shortcut.display) \(conflict)。请重新指定。") }
                }
            }
        }
        return settings
    }
    func dispose() { recorder.stopRecording() }
}
