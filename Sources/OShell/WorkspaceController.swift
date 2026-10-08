// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class WorkspaceController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    lazy var appUpdater = AppUpdater(workspace: self)
    let store: ConfigurationStore
    var configuration: Configuration
    private(set) var configurationRevision = 0
    private var sessionManager: SessionManager?
    private let quickButton = NSPopUpButton(frame: .zero, pullsDown: true)
    var quickMenu: NSMenu? { didSet { rebuildQuickLinks() } }
    private let tabStrip = TabStripView()
    let sessionLinkBar = SessionLinkBar()
    var sessionLinkHeight: NSLayoutConstraint!
    let currentPropertiesButton = NSButton(), defaultPropertiesButton = NSButton()
    let splitButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let tabGroupButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let arrangementButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var arrangement: TabArrangement = .tabs
    private var arrangingView: TabArrangementView?
    let idleMemoryReclaimer = IdleMemoryReclaimer()
    let terminalHost = TabDropHost()
    var customTabLayout: TabGroupNode?
    var activeTabGroupID: UUID?
    var groupStrips = [(TabGroupNode, TabStripView)]()
    private var tabStripHeight: NSLayoutConstraint!
    private let composerHost = NSView()
    private(set) var loadedComposer: CommandComposer?
    var composer: CommandComposer {
        if let loadedComposer { return loadedComposer }
        let view = CommandComposer(); view.isHidden = true
        view.onTargets = { [weak self] in self?.chooseComposerTargets() }
        view.onSend = { [weak self] text, append in self?.sendComposed(text, appendReturn: append) }
        view.onClose = { [weak self] in self?.toggleComposer() }
        view.translatesAutoresizingMaskIntoConstraints = false; composerHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: composerHost.leadingAnchor), view.trailingAnchor.constraint(equalTo: composerHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: composerHost.topAnchor), view.bottomAnchor.constraint(equalTo: composerHost.bottomAnchor)])
        loadedComposer = view
        return view
    }
    var composerHeight: NSLayoutConstraint!
    var composerTargets = Set<UUID>()
    var syncTargets = Set<UUID>()
    let quickSendBar = QuickSendBar()
    var quickSendScope: QuickSendScope = .current
    var quickSendSelected = Set<UUID>()
    var quickSendSelectedGroups = Set<UUID>()
    let defaultQuickSendGroupID = UUID()
    var quickSendHeight: NSLayoutConstraint!
    private var quickSendVisibilityObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var quickSendRefreshPending = false
    let syncIndicator = NSTextField(labelWithString: "")
    let stopSyncButton = NSButton()
    var commandManager: QuickCommandManager?
    var highlightManager: HighlightManager?
    var fileWindows = [RemoteFileWindow]()
    var commandMenu: NSMenu? { didSet { rebuildCommandMenu() } }
    private let welcome = NSView()
    private let recordButton = NSButton()
    private(set) var tabs = [TerminalTab]()
    private var tabHistory = [UUID]()
    private(set) var selectedTab: TerminalTab? {
        didSet {
            guard selectedTab !== oldValue else { return }
            tabHistory.removeAll { id in id == selectedTab?.id || !tabs.contains(where: { $0.id == id }) }
            if let selectedTab { tabHistory.insert(selectedTab.id, at: 0) }
        }
    }
    var loadFailed = false
    private(set) var isSecurityUnlocked = false
    private var startupDecision: Bool?
    private var startupWaiters = [(Bool) -> Void]()
    let masterWarning = NSView()
    var masterWarningHeight: NSLayoutConstraint!
    func whenStartupUnlocked(_ completion: @escaping (Bool) -> Void) {
        if let startupDecision { completion(startupDecision) } else { startupWaiters.append(completion) }
    }
    func completeStartupUnlock(_ allowed: Bool) {
        guard startupDecision == nil else { return }
        startupDecision = allowed; isSecurityUnlocked = allowed
        let callbacks = startupWaiters; startupWaiters.removeAll()
        callbacks.forEach { $0(allowed) }
    }
    init(store: ConfigurationStore) {
        self.store = store
        do { configuration = try store.load() }
        catch { configuration = Configuration(); loadFailed = true }
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OShell"; window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true
        super.init(window: window)
        PasswordVault.shared.configureLocalStorage(directory: store.url.deletingLastPathComponent())
        PasswordVault.shared.configureProtection(configuration)
        if !loadFailed && !configuration.hasMasterPassword { completeStartupUnlock(true) }
        window.delegate = self; window.center(); window.setFrameAutosaveName(CommandLine.arguments.contains("--memory-profile") ? "OShell.memory-profile" : "OShell.main")
        quickSendScope = configuration.preferences.quickSendScope
        ApplicationAppearance.apply(configuration.preferences.interfaceTheme)
        ShortcutRuntime.current = configuration.preferences.keyboardShortcuts
        buildInterface(); rebuildQuickLinks(); refreshSelection()
        quickSendVisibilityObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.quickSendScope == .visible, let clip = note.object as? NSClipView, clip.window === self.window, !self.quickSendRefreshPending else { return }
            self.quickSendRefreshPending = true
            DispatchQueue.main.async { [weak self] in self?.quickSendRefreshPending = false; self?.refreshQuickSendBar() }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in self?.markSelectedOutputRead() }
    }
    deinit {
        if let quickSendVisibilityObserver { NotificationCenter.default.removeObserver(quickSendVisibilityObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
    func windowDidBecomeKey(_ notification: Notification) { markSelectedOutputRead() }
    func windowDidDeminiaturize(_ notification: Notification) { markSelectedOutputRead() }
    var isObservingSelectedTab: Bool { NSApp.isActive && window?.isKeyWindow == true && window?.isVisible == true && window?.isMiniaturized == false }
    func markSelectedOutputRead() {
        guard isObservingSelectedTab, let selectedTab, selectedTab.hasUnreadOutput else { return }
        selectedTab.markOutputRead(); refreshTabTitles()
    }
    func windowDidResize(_ notification: Notification) { refreshQuickSendBar() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() {
        guard isSecurityUnlocked else { return }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    private func iconButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(oshellSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading; button.bezelStyle = .texturedRounded; button.controlSize = .regular
        return button
    }
    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let new = iconButton("新建", "plus", #selector(newSession))
        let connect = iconButton("会话管理", "folder", #selector(showSessionManager))
        connect.toolTip = "会话管理（Esc 关闭）"
        quickButton.bezelStyle = .texturedRounded; quickButton.setAccessibilityLabel("快捷连接")
        let local = iconButton("本地", "terminal", #selector(newLocal))
        arrangementButton.bezelStyle = .texturedRounded
        arrangementButton.toolTip = "排列已打开的标签"
        arrangementButton.setAccessibilityLabel("选项卡排列")
        let arrangementMenu = NSMenu()
        arrangementMenu.addItem(withTitle: "排列", action: nil, keyEquivalent: "")
        for mode in TabArrangement.allCases {
            let item = arrangementMenu.addItem(withTitle: mode.title, action: #selector(changeArrangement(_:)), keyEquivalent: "")
            item.tag = mode.rawValue; item.target = self; item.toolTip = mode.hint
        }
        arrangementButton.menu = arrangementMenu
        tabGroupButton.bezelStyle = .texturedRounded; tabGroupButton.setAccessibilityLabel("标签组")
        tabGroupButton.widthAnchor.constraint(equalToConstant: 76).isActive = true
        tabGroupButton.toolTip = "新建、命名和显示/隐藏标签组；隐藏不会断开连接"
        let tools = NSPopUpButton(frame: .zero, pullsDown: true); tools.bezelStyle = .texturedRounded
        let toolsMenu = NSMenu(); toolsMenu.addItem(withTitle: "工具", action: nil, keyEquivalent: "")
        for (title, action) in [("快捷链接栏", #selector(toggleSessionLinkBar)), ("快速发送栏", #selector(toggleQuickSendBar)), ("撰写窗", #selector(toggleComposer)), ("同步输入…", #selector(configureSyncInput)), ("停止同步输入", #selector(stopSyncInput)), ("快速命令管理器…", #selector(showQuickCommands)), ("文件管理…", #selector(showFiles)), ("突出显示集…", #selector(showHighlights))] {
            toolsMenu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        tools.menu = toolsMenu
        let find = iconButton("搜索", "magnifyingglass", #selector(findInTerminal))
        recordButton.title = "记录"; recordButton.target = self; recordButton.action = #selector(toggleLogging)
        recordButton.image = NSImage(oshellSymbolName: "record.circle", accessibilityDescription: "日志记录")
        recordButton.imagePosition = .imageLeading; recordButton.bezelStyle = .texturedRounded
        let settings = iconButton("", "gearshape", #selector(showPreferences)); settings.toolTip = "设置"
        configurePropertyButtons()
        let toolbar = WorkspaceToolbar(views: [connect, quickButton, new, local, currentPropertiesButton, defaultPropertiesButton, tools, tabGroupButton, splitButton, arrangementButton, syncIndicator, stopSyncButton, NSView(), find, recordButton, settings])
        toolbar.identifier = .init("workspace.toolbar")
        toolbar.compactButtons = [new, local, find, recordButton]
        for (button, label) in [(new, "新建会话"), (local, "本地终端"), (find, "搜索终端"), (recordButton, "记录终端日志")] {
            button.toolTip = label; button.setAccessibilityLabel(label)
        }
        toolbar.orientation = .horizontal; toolbar.spacing = 6
        toolbar.detachesHiddenViews = true
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        let workspace = makeWorkspace()
        syncIndicator.textColor = .systemOrange; syncIndicator.font = .systemFont(ofSize: 11, weight: .semibold)
        stopSyncButton.image = NSImage(oshellSymbolName: "stop.circle.fill", accessibilityDescription: "停止同步输入"); stopSyncButton.isBordered = false; stopSyncButton.oshellContentTintColor = .systemOrange; stopSyncButton.toolTip = "停止同步输入"; stopSyncButton.setAccessibilityLabel("停止同步输入"); stopSyncButton.target = self; stopSyncButton.action = #selector(stopSyncInput)
        syncIndicator.isHidden = true; stopSyncButton.isHidden = true
        syncIndicator.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stopSyncButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        stopSyncButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let divider = NSBox(); divider.boxType = .separator
        configureSessionLinkBar()
        sessionLinkHeight = sessionLinkBar.heightAnchor.constraint(equalToConstant: configuration.sessionLinks.visible ? 30 : 0)
        configureMasterWarning()
        [toolbar, masterWarning, sessionLinkBar, workspace, divider].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor), toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor), toolbar.heightAnchor.constraint(equalToConstant: 40),
            masterWarning.topAnchor.constraint(equalTo: toolbar.bottomAnchor), masterWarning.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            masterWarning.trailingAnchor.constraint(equalTo: content.trailingAnchor), masterWarningHeight,
            sessionLinkBar.topAnchor.constraint(equalTo: masterWarning.bottomAnchor), sessionLinkBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sessionLinkBar.trailingAnchor.constraint(equalTo: content.trailingAnchor), sessionLinkHeight,
            divider.topAnchor.constraint(equalTo: sessionLinkBar.bottomAnchor), divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            workspace.topAnchor.constraint(equalTo: divider.bottomAnchor), workspace.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            workspace.trailingAnchor.constraint(equalTo: content.trailingAnchor), workspace.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }
    func configureTerminalTabStrip(_ strip: TabStripView) {
        strip.allowsTabDragging = true
        strip.onDragEnd = { [weak self] in self?.terminalHost.clearPreview() }
        strip.onSelect = { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
            self.select(tab)
        }
        strip.onClose = { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
            self.close(tab)
        }
        strip.onDuplicate = { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
            self.duplicateTab(tab)
        }
        strip.contextMenu = { [weak self] in self?.sessionTabContextMenu($0) }
        strip.setAddDescription("新建空白标签页")
        strip.onAdd = { [weak self] in self?.newBlankTab() }
    }
    private func makeWorkspace() -> NSView {
        let workspace = NSView()
        configureTerminalTabStrip(tabStrip)
        terminalHost.target = { [weak self] source, point in self?.tabDropTarget(source: source, point: point) }
        terminalHost.drop = { [weak self] source, target in
            if let group = target.group { return self?.moveTab(source, toGroup: group) ?? false }
            if let tab = target.tab { return self?.moveTab(source, beside: tab, position: target.position) ?? false }
            return false
        }
        tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: TabStripView.barHeight)
        composerHeight = composerHost.heightAnchor.constraint(equalToConstant: 0)
        quickSendHeight = quickSendBar.heightAnchor.constraint(equalToConstant: configuration.preferences.quickSendBarVisible ? 36 : 0)
        quickSendBar.isHidden = !configuration.preferences.quickSendBarVisible
        quickSendBar.onScope = { [weak self] in self?.chooseQuickSendScope($0) }
        quickSendBar.onSend = { [weak self] in self?.sendQuickCommand($0) ?? false }
        quickSendBar.onMultiline = { [weak self] in self?.composeQuickCommand($0) }
        quickSendBar.onManage = { [weak self] in self?.showQuickCommands() }
        quickSendBar.onEscape = { [weak self] in self?.selectedTab?.activePane.activate() }
        [tabStrip, terminalHost, composerHost, quickSendBar].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; workspace.addSubview($0) }
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: workspace.topAnchor), tabStrip.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: workspace.trailingAnchor), tabStripHeight,
            terminalHost.topAnchor.constraint(equalTo: tabStrip.bottomAnchor, constant: 2), terminalHost.leadingAnchor.constraint(equalTo: workspace.leadingAnchor, constant: 4),
            terminalHost.trailingAnchor.constraint(equalTo: workspace.trailingAnchor, constant: -4), terminalHost.bottomAnchor.constraint(equalTo: composerHost.topAnchor, constant: -2),
            composerHost.leadingAnchor.constraint(equalTo: workspace.leadingAnchor), composerHost.trailingAnchor.constraint(equalTo: workspace.trailingAnchor), composerHost.bottomAnchor.constraint(equalTo: quickSendBar.topAnchor), composerHeight,
            quickSendBar.leadingAnchor.constraint(equalTo: workspace.leadingAnchor), quickSendBar.trailingAnchor.constraint(equalTo: workspace.trailingAnchor), quickSendBar.bottomAnchor.constraint(equalTo: workspace.bottomAnchor), quickSendHeight
        ])
        let icon = NSImageView(image: NSImage(oshellSymbolName: "terminal", accessibilityDescription: "OShell") ?? NSImage())
        icon.oshellContentTintColor = .systemTeal; icon.widthAnchor.constraint(equalToConstant: 62).isActive = true; icon.heightAnchor.constraint(equalToConstant: 62).isActive = true
        let title = NSTextField(labelWithString: "OShell"); title.font = .systemFont(ofSize: 30, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "连接你的服务器，专注每一条命令。")
        subtitle.textColor = .secondaryLabelColor; subtitle.font = .systemFont(ofSize: 14)
        let buttons = NSStackView(views: [iconButton("新建 SSH 会话", "plus", #selector(newSession)), iconButton("打开本地终端", "terminal", #selector(newLocal))]); buttons.spacing = 12
        let shortcuts = NSTextField(labelWithString: "工具栏可新建终端、排列多个会话和搜索；快捷键可在设置中自定义。")
        shortcuts.font = .systemFont(ofSize: 11); shortcuts.textColor = .tertiaryLabelColor
        let center = NSStackView(views: [icon, title, subtitle, buttons, shortcuts]); center.orientation = .vertical; center.spacing = 18; center.alignment = .centerX
        center.translatesAutoresizingMaskIntoConstraints = false; welcome.addSubview(center)
        NSLayoutConstraint.activate([center.centerXAnchor.constraint(equalTo: welcome.centerXAnchor), center.centerYAnchor.constraint(equalTo: welcome.centerYAnchor, constant: -12)])
        showWelcome()
        return workspace
    }
    private func install(_ view: NSView) {
        terminalHost.subviews.forEach { $0.removeFromSuperview() }
        view.frame = terminalHost.bounds; view.autoresizingMask = [.width, .height]; terminalHost.addSubview(view)
    }
    private func showWelcome() { install(welcome) }
    private var selectedProfile: SessionProfile? { sessionManager?.selectedProfile }
    @discardableResult func saveConfiguration(_ value: Configuration, updatingMasterProtection: Bool = false) -> Bool {
        guard !loadFailed else { Dialogs.message("原配置读取失败，本次启动不会覆盖配置。"); return false }
        do {
            var normalized = PasswordVault.shared.currentCredentials(in: value)
            var migrated: CredentialRotation?
            if !updatingMasterProtection {
                normalized.masterPasswordVerifier = configuration.masterPasswordVerifier
                if normalized.masterPasswordVerifier == nil,
                   normalized.hasMasterPassword || configuration.hasMasterPassword {
                    guard let master = PasswordVault.shared.cachedMaster else { throw ModelError.invalid("请先解锁主密码再保存配置。") }
                    let protected = configuration.hasMasterPassword ? configuration : normalized
                    try MasterPasswordProtection.verifyStartup(protected, password: master)
                    migrated = try MasterPasswordProtection.enabling(normalized, password: master, credentialKey: { try PasswordVault.shared.migrationKey($0, master: master) })
                    normalized = migrated!.configuration
                }
            }
            try normalized.migrateFileSessions()
            try normalized.sessionDefaults.validate()
            normalized.sessionLinks.normalize(profiles: normalized.profiles)
            normalized.normalizeSessionLinkDirectories()
            try store.save(normalized); configuration = normalized; configurationRevision += 1
            if let migrated, let master = PasswordVault.shared.cachedMaster { PasswordVault.shared.acceptRotation(migrated, master: master) }
            PasswordVault.shared.configureProtection(configuration); refreshMasterWarning()
            rebuildQuickLinks(); rebuildCommandMenu(); applyHighlightConfiguration(); sessionManager?.reload(); refreshQuickSendBar(); ShortcutRuntime.install(configuration.preferences.keyboardShortcuts); return true
        } catch { Dialogs.message("保存配置失败：\(error.localizedDescription)"); return false }
    }
    private func persist() { _ = saveConfiguration(configuration) }
    @objc func showSessionManager() {
        if sessionManager == nil { sessionManager = SessionManager(workspace: self) }
        sessionManager?.show()
    }
    func showSessionDirectory(_ directory: String) {
        showSessionManager(); sessionManager?.revealDirectory(directory)
    }
    func showFileSessions(selection: @escaping (SessionProfile) -> Void) {
        if sessionManager == nil { sessionManager = SessionManager(workspace: self) }
        sessionManager?.showFiles(selection: selection)
    }
    @objc func importSessions() { showSessionManager(); sessionManager?.importSessions() }
    @objc func exportSessions() { showSessionManager(); sessionManager?.exportAll() }
    @objc func newSession() { createSession(kind: .ssh) }
    func createSession(kind: SessionKind) {
        guard let profile = Dialogs.session(profiles: credentialProfiles, directories: SessionDirectory.all(configuration), initialDirectory: sessionManager?.currentDirectory ?? "服务器", kind: kind, defaults: configuration.sessionDefaults) else { return }
        var value = configuration; value.profiles.append(profile)
        if saveConfiguration(value) { if sessionManager == nil { showSessionManager() }; sessionManager?.reveal(profile); sessionManager?.showPreservingMode() }
    }
    @objc func editSession() {
        guard let selected = selectedProfile, selected.kind != .local,
              let profile = Dialogs.session(selected, profiles: credentialProfiles, directories: SessionDirectory.all(configuration), defaults: configuration.sessionDefaults),
              let index = configuration.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var value = configuration; value.profiles[index] = profile
        let linkID = sessionManager?.selectedLink?.id
        if saveConfiguration(value) {
            if let linkID { sessionManager?.revealLink(linkID) } else { sessionManager?.reveal(profile) }
        }
    }
    @objc func deleteSession() {
        guard let profile = selectedProfile, Dialogs.confirm("删除“\(profile.name)”？", text: "已打开的连接继续保留。", action: "删除") else { return }
        var value = configuration; value.profiles.removeAll { $0.id == profile.id }; _ = saveConfiguration(value)
    }
    @objc func connectSelected() { if let profile = selectedProfile { open(profile) } else { showSessionManager() } }
    @objc private func connectQuick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let profile = configuration.profiles.first(where: { $0.id == id }) else { return }; open(profile)
    }
    private func rebuildQuickLinks() {
        rebuildSessionLinkBar()
        func populate(_ menu: NSMenu, directory: String) {
            let profiles = configuration.profiles.filter(\.quickConnect)
            for child in SessionDirectory.all(configuration) where SessionDirectory.parent(child) == directory && profiles.contains(where: { SessionDirectory.contains($0.group, in: child) }) {
                let item = NSMenuItem(title: String(child.split(separator: "/").last!), action: nil, keyEquivalent: "")
                item.image = NSImage(oshellSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu(); item.submenu = submenu; menu.addItem(item); populate(submenu, directory: child)
            }
            for profile in profiles.filter({ $0.group == directory }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                let item = NSMenuItem(title: profile.name + " · " + profile.kind.title, action: #selector(connectQuick(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = profile.id; item.toolTip = profile.host; menu.addItem(item)
            }
        }
        let menu = NSMenu(); menu.addItem(withTitle: "快捷连接", action: nil, keyEquivalent: "")
        populate(menu, directory: "")
        if menu.items.count == 1 { let item = menu.addItem(withTitle: "暂无快捷会话", action: nil, keyEquivalent: ""); item.isEnabled = false }
        menu.addItem(.separator()); menu.addItem(withTitle: "管理会话…", action: #selector(showSessionManager), keyEquivalent: "").target = self
        quickButton.menu = menu
        quickMenu?.removeAllItems(); if let quickMenu { populate(quickMenu, directory: ""); quickMenu.addItem(.separator()); quickMenu.addItem(withTitle: "管理会话…", action: #selector(showSessionManager), keyEquivalent: "").target = self }
    }
    func duplicateTab(_ tab: TerminalTab) {
        guard let pane = replica(of: tab.activePane) else { return }
        let duplicate = TerminalTab(pane); tabs.append(duplicate); selectedTab = duplicate
        rebuildWorkspace(); select(duplicate)
    }
    private func replica(of source: TerminalPane) -> TerminalPane? {
        let group = source.sshConnectionGroup?.isExternal == true ? source.sshConnectionGroup : nil
        if let group, !group.isAvailable {
            Dialogs.message(group.isAuthenticated ? "已认证的堡垒机连接已失效，请从 USM 重新打开会话。" : "堡垒机会话尚未完成认证，请登录完成后再新建标签。")
            return nil
        }
        return makePane(source.profile, terminalType: source.externalTerminalType, connectionGroup: group, reuseConnection: group != nil, blank: source.isBlank)
    }
    @objc func newBlankTab() {
        guard isSecurityUnlocked else { return }
        let tab = TerminalTab(makePane(.local, blank: true)); tabs.append(tab); selectedTab = tab
        rebuildWorkspace(); select(tab)
    }
    func canCopySSHChannel(_ tab: TerminalTab) -> Bool {
        let pane = tab.activePane
        return pane.profile.kind == .ssh && !pane.ended && !pane.isShutdown && pane.sessionReady && pane.sshConnectionGroup?.isAvailable == true
    }
    @objc func copyTabSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabGroupID = customTabLayout?.group(containing: id)?.id
        if tab.activePane.isBlank { newBlankTab(); return }
        let pane = makePane(tab.activePane.profile, terminalType: tab.activePane.externalTerminalType)
        let copy = TerminalTab(pane); tabs.append(copy); selectedTab = copy; rebuildWorkspace(); select(copy)
    }
    @objc func copyTabSSHChannel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.first(where: { $0.id == id }), canCopySSHChannel(tab) else { return }
        let source = tab.activePane
        activeTabGroupID = customTabLayout?.group(containing: id)?.id
        let pane = makePane(source.profile, terminalType: source.externalTerminalType, connectionGroup: source.sshConnectionGroup, reuseConnection: true)
        let copy = TerminalTab(pane); tabs.append(copy); selectedTab = copy; rebuildWorkspace(); select(copy)
    }
    @objc func newBlankFromTab(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { activeTabGroupID = customTabLayout?.group(containing: id)?.id }
        newBlankTab()
    }
    @objc func newLocal() { open(configuration.profiles.first(where: { $0.kind == .local }) ?? .local) }
    private func makePane(_ profile: SessionProfile, oneTimePassword: String? = nil, terminalType: String? = nil, connectionGroup: SSHConnectionGroup? = nil, reuseConnection: Bool = false, blank: Bool = false) -> TerminalPane {
        idleMemoryReclaimer.cancel()
        let knownHosts = store.url.deletingLastPathComponent().appendingPathComponent("known_hosts")
        try? FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pane = TerminalPane(profile: profile, preferences: configuration.preferences, knownHostsFile: knownHosts, oneTimePassword: oneTimePassword, terminalType: terminalType, connectionGroup: connectionGroup, reuseConnection: reuseConnection, blank: blank)
        pane.onFocus = { [weak self] pane in
            guard let self, let tab = self.tabs.first(where: { $0.layout.panes.contains(where: { $0 === pane }) }) else { return }
            tab.activePane = pane
            if self.selectedTab !== tab { self.select(tab, focus: false) }
            else { self.refreshSelection() }
        }
        pane.onState = { [weak self] in self?.refreshSelection() }
        pane.onOutput = { [weak self] pane in self?.recordTerminalOutput(pane) }
        pane.onCloseRequested = { [weak self] pane in
            guard let self, pane.ended,
                  let tab = self.tabs.first(where: { $0.layout.panes.contains(where: { $0 === pane }) }) else { return }
            // An ended terminal can close synchronously during a quick-send
            // broadcast. Advance terminal focus only if a terminal owned it;
            // text fields/composers must keep their current field editor.
            let focusTerminal = self.inputPanes.contains { self.window?.firstResponder === $0.terminal }
            self.close(tab, focusRemainingTerminal: focusTerminal)
        }
        pane.onUserInput = { [weak self] pane, bytes in self?.routeKeyboard(pane, bytes: bytes) ?? false }
        pane.onPaste = { [weak self] pane, text in self?.pasteText(text, from: pane) }
        pane.onFilesDropped = { [weak self] pane, urls in self?.openFiles(for: pane.profile, directory: pane.remoteDirectory, uploading: urls) }
        pane.applyHighlights(configuration.highlightSets.first { $0.id == configuration.preferences.highlightSetID })
        pane.onError = { message in Dialogs.message(message) }
        return pane
    }
    func open(_ profile: SessionProfile) {
        guard isSecurityUnlocked else { return }
        if profile.kind.isFileSession { openFiles(for: profile, directory: profile.initialDirectory); return }
        let tab = TerminalTab(makePane(profile)); tabs.append(tab); selectedTab = tab
        rebuildWorkspace(); select(tab)
    }
    func openExternal(_ request: ZOCLaunchRequest) {
        guard isSecurityUnlocked else { return }
        do {
            let profile = try request.profile()
            let group = try SSHConnectionGroup(profile: profile, external: true)
            let tab = TerminalTab(makePane(profile, oneTimePassword: request.password, terminalType: request.terminalType, connectionGroup: group))
            tabs.append(tab); selectedTab = tab; rebuildWorkspace(); select(tab)
            show(); NSApp.activate(ignoringOtherApps: true)
        } catch { Dialogs.message("无法打开外部启动会话，请检查连接参数。") }
    }
    /// Each visible strip is an independent numbering scope. The underlying
    /// UUID remains the identity when closing/moving tabs changes ordinals.
    var tabNumbers: [UUID: Int] {
        let groups = customTabLayout?.groups.map(\.tabs) ?? [tabs.map(\.id)]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { ids in ids.enumerated().map { ($0.element, $0.offset + 1) } })
    }
    var numberedTabs: [TerminalTab] {
        guard let layout = customTabLayout else { return tabs }
        let visible = layout.groups.filter { !$0.isHidden }
        let group = visible.first { $0.id == activeTabGroupID }
            ?? visible.first { group in selectedTab.map { group.tabs.contains($0.id) } ?? false } ?? visible.first
        return group?.tabs.compactMap { id in tabs.first { $0.id == id } } ?? []
    }
    private func refreshTabTitles() {
        let numbers = tabNumbers
        tabStrip.update(tabs: tabs, selected: selectedTab, numbers: numbers)
        for (group, strip) in groupStrips {
            strip.update(tabs: group.tabs.compactMap { id in tabs.first { $0.id == id } }, selected: tabs.first { $0.id == group.active }, numbers: numbers)
            configureGroupHeading(strip, group: group)
        }
        refreshTabGroupMenu()
    }
    private func recordTerminalOutput(_ pane: TerminalPane) {
        if isObservingSelectedTab, selectedTab?.layout.panes.contains(where: { $0 === pane }) == true { return }
        guard !pane.isShutdown, tabs.contains(where: { $0.layout.panes.contains(where: { $0 === pane }) }) else { return }
        pane.markOutputUnread()
        // Called only on the first unread chunk; no per-byte counters or blinking timers.
        refreshTabTitles()
    }
    private func refreshSelection() {
        refreshSessionLinkAddButton(); refreshToolbarActions()
        if isObservingSelectedTab { selectedTab?.markOutputRead() }
        for tab in tabs {
            for pane in tab.layout.panes { pane.setSelected(tab === selectedTab && pane === tab.activePane) }
        }
        refreshTabTitles(); refreshStatus()
    }
    func rebuildWorkspace() {
        // Detach existing terminal views before disposing of the old arrangement.
        // No PTY or session is created or stopped by rearranging.
        tabs.forEach { $0.layout.view.removeFromSuperview() }
        arrangingView = nil; groupStrips.removeAll(); reconcileTabGroups()
        tabStrip.isHidden = customTabLayout != nil; tabStripHeight.constant = customTabLayout == nil ? TabStripView.barHeight : 0
        if let customTabLayout {
            if let root = buildTabGroupView(customTabLayout) {
                let view = TabArrangementView(root: root); arrangingView = view; install(view)
            } else { install(hiddenTabGroupsView()) }
        } else if let selectedTab, arrangement == .tabs { install(selectedTab.layout.view) }
        else if !tabs.isEmpty {
            let view = TabArrangementView(tabs: tabs, mode: arrangement)
            arrangingView = view; install(view); view.equalize()
        } else { showWelcome() }
        terminalHost.layoutSubtreeIfNeeded()
        let visible = visibleTerminalTabs
        visible.flatMap { $0.layout.panes }.forEach { $0.prepareForDisplay() }
        refreshSelection()
    }
    func updateGroupSelection(_ tab: TerminalTab?, group: UUID?) {
        guard tab == nil || tabs.contains(where: { $0 === tab }) else { return }
        selectedTab = tab; activeTabGroupID = group
    }
    func select(_ tab: TerminalTab, focus: Bool = true) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        selectedTab = tab
        if let group = customTabLayout?.group(containing: tab.id) { activeTabGroupID = group.id }
        if let group = customTabLayout?.group(containing: tab.id), group.active != tab.id || group.isHidden {
            group.isHidden = false; group.active = tab.id; rebuildWorkspace()
        }
        if customTabLayout == nil, arrangement == .tabs, tab.layout.view.superview !== terminalHost {
            install(tab.layout.view)
        }
        terminalHost.layoutSubtreeIfNeeded()
        tab.layout.panes.forEach { $0.prepareForDisplay() }
        // Clicking another visible terminal changes focus without rebuilding the grid.
        if focus, window?.firstResponder !== tab.activePane.terminal { tab.activePane.activate() }
        refreshSelection(); tabStrip.revealSelection()
        groupStrips.first { $0.0.tabs.contains(tab.id) }?.1.revealSelection()
        if arrangement != .tabs || customTabLayout != nil { tab.activePane.view.scrollToVisible(tab.activePane.view.bounds) }
    }
    func arrange(_ mode: TabArrangement) {
        if mode != .tabs, let root = customTabLayout, root.groups.contains(where: { $0.name != nil }) {
            customTabLayout = arrangedGroupTree(root.groups, mode: mode)
        } else { customTabLayout = nil }
        arrangement = mode
        if customTabLayout == nil, selectedTab == nil { selectedTab = tabs.first }
        rebuildWorkspace()
        if let selectedTab { select(selectedTab) }
    }
    @objc func changeArrangement(_ sender: NSMenuItem) {
        if let mode = TabArrangement(rawValue: sender.tag) { arrange(mode) }
    }
    private func close(_ tab: TerminalTab, focusRemainingTerminal: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tab.layout.panes.contains(where: \.hasActiveProcess),
           !Dialogs.confirm("关闭此标签？", text: "此标签中的连接、本机工具与文件传输会结束。", action: "关闭") { return }
        let wasSelected = selectedTab === tab
        var groupNeighbor: TerminalTab?
        if let group = customTabLayout?.group(containing: tab.id), let position = group.tabs.firstIndex(of: tab.id) {
            let remaining = group.tabs.filter { $0 != tab.id }
            if !remaining.isEmpty {
                let nextID = remaining[min(position, remaining.count - 1)]
                groupNeighbor = tabs.first { $0.id == nextID }
            }
        }
        tab.layout.panes.forEach { $0.shutdown() }; tab.layout.view.removeFromSuperview(); tabs.remove(at: index)
        tabHistory.removeAll { $0 == tab.id }
        if wasSelected {
            let visible = tabs.filter { customTabLayout?.group(containing: $0.id)?.isHidden != true }
            let adjacent = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
            selectedTab = groupNeighbor ?? adjacent.flatMap { candidate in visible.contains(where: { $0 === candidate }) ? candidate : nil } ?? visible.first
            if let selectedTab { activeTabGroupID = customTabLayout?.group(containing: selectedTab.id)?.id }
        }
        rebuildWorkspace()
        if let selectedTab { select(selectedTab, focus: focusRemainingTerminal) }
        if tabs.isEmpty { idleMemoryReclaimer.schedule { [weak self] in self?.tabs.isEmpty == true } }
    }
    @objc func closeTab() { if let tab = selectedTab { close(tab) } }
    @objc func closePane() {
        guard let tab = selectedTab else { window?.close(); return }
        guard tab.layout.panes.count > 1 else { close(tab); return }
        let pane = tab.activePane
        if pane.hasActiveProcess, !Dialogs.confirm("关闭当前分屏？", text: "当前连接、本机工具与传输会结束。", action: "关闭") { return }
        pane.shutdown()
        if let layout = tab.layout.removing(pane.id) {
            tab.layout = layout; tab.activePane = layout.panes[0]; rebuildWorkspace(); select(tab)
        }
    }
    @objc func splitVertical() { split(vertical: true) }
    @objc func splitHorizontal() { split(vertical: false) }
    private func split(vertical: Bool) {
        guard let tab = selectedTab else { newLocal(); return }
        let original = tab.activePane
        guard let pane = replica(of: original) else { return }
        let splitter = NSSplitView(); splitter.isVertical = vertical; splitter.dividerStyle = .thin
        let frame = original.view.frame
        original.view.removeFromSuperview()
        splitter.frame = frame; splitter.addArrangedSubview(original.view); splitter.addArrangedSubview(pane.view)
        let node = PaneLayout.split(splitter, .pane(original), .pane(pane))
        tab.layout = tab.layout.replacing(original.id, with: node); tab.activePane = pane
        rebuildWorkspace(); select(tab); splitter.adjustSubviews()
        let extent = vertical ? splitter.bounds.width : splitter.bounds.height
        splitter.setPosition(extent / 2, ofDividerAt: 0)
        pane.activate()
    }
    @objc func reconnect() {
        guard let tab = selectedTab else { return }
        let old = tab.activePane
        if old.hasActiveProcess, !Dialogs.confirm("重新连接？", text: "当前连接或本机工具将结束，并重新建立原会话连接。", action: "重新连接") { return }
        guard let pane = replica(of: old) else { return }
        old.shutdown()
        tab.layout = tab.layout.replacing(old.id, with: .pane(pane)); tab.activePane = pane
        rebuildWorkspace(); select(tab)
    }
    @objc func findInTerminal() {
        if let manager = NSApp.keyWindow?.windowController as? SessionManager { manager.focusSearch(); return }
        guard NSApp.keyWindow == nil || NSApp.keyWindow === window, window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        selectedTab?.activePane.searchPanel.show()
    }
    @objc func findNextInTerminal() { selectedTab?.activePane.searchPanel.navigate(next: true) }
    @objc func findPreviousInTerminal() { selectedTab?.activePane.searchPanel.navigate(next: false) }
    @objc func toggleLogging() {
        guard let pane = selectedTab?.activePane, let window else { return }
        if pane.isLogging { pane.stopLogging(); return }
        let panel = NSSavePanel(); panel.title = "保存终端日志"; panel.canCreateDirectories = true
        let date = DateFormatter(); date.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = pane.title.replacingOccurrences(of: "/", with: "_")
        panel.nameFieldStringValue = "\(safeName)-\(date.string(from: Date())).log"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, !pane.ended else { return }
            do { try pane.startLogging(to: url) } catch { Dialogs.message(error.localizedDescription) }
        }
    }
    @objc func showPreferences() { editPreferences(appearanceSelected: false) }
    @objc func showAppearancePreferences() { editPreferences(appearanceSelected: true) }
    func editPreferences(appearanceSelected: Bool, updatesSelected: Bool = false) {
        guard let preferences = Dialogs.preferences(configuration.preferences, appearanceSelected: appearanceSelected, updatesSelected: updatesSelected) else { return }
        if appUpdater.isBusy && preferences.updateRepository != configuration.preferences.updateRepository { Dialogs.message("更新正在进行，请完成或取消后再修改更新仓库。"); return }
        var value = configuration; value.preferences = preferences
        guard saveConfiguration(value) else { return }
        do { try appUpdater.configure() } catch { Dialogs.message(error.localizedDescription) }
        ApplicationAppearance.apply(preferences.interfaceTheme)
        tabs.flatMap { $0.layout.panes }.forEach { $0.apply(preferences) }; refreshSelection()
    }
    @objc func lockPasswords() { PasswordVault.shared.lock() }
    @discardableResult func selectTab(number: Int) -> Bool {
        let candidates = numberedTabs
        guard isSecurityUnlocked, window?.attachedSheet == nil, NSApp.modalWindow == nil,
              number > 0, number <= candidates.count else { return false }
        select(candidates[number - 1]); return true
    }
    @objc func selectNumberedTab(_ sender: NSMenuItem) { _ = selectTab(number: sender.tag) }
    @objc func chooseTabNumber() {
        guard isSecurityUnlocked, !numberedTabs.isEmpty, window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        let alert = PopupAlert(); alert.messageText = "跳转到标签"
        alert.informativeText = "输入当前分屏窗口的标签编号（1–\(numberedTabs.count)）；各标签的快捷键可在设置中自定义。"
        alert.addButton(withTitle: "跳转"); alert.addButton(withTitle: "取消")
        let input = NSTextField(string: String(selectedTab.flatMap { tabNumbers[$0.id] } ?? 1))
        input.identifier = .init("tab.number"); input.setAccessibilityLabel("标签编号")
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        alert.accessoryView = input; alert.window.initialFirstResponder = input
        while alert.runModal() == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(text), selectTab(number: number) { return }
            alert.informativeText = "请输入当前分屏窗口内 1–\(numberedTabs.count) 范围的有效编号。"; input.selectText(nil)
        }
    }
    @objc func nextTab() { cycleTab(1) }
    @objc func previousTab() { cycleTab(-1) }
    @objc func refreshCurrentHostIdentity() { selectedTab?.activePane.refreshHostIdentity() }
    @objc func lastUsedTab() {
        guard window?.attachedSheet == nil, NSApp.modalWindow == nil,
              let id = tabHistory.first(where: { $0 != selectedTab?.id && customTabLayout?.group(containing: $0)?.isHidden != true }),
              let tab = tabs.first(where: { $0.id == id }) else { return }
        select(tab)
    }
    private func cycleTab(_ delta: Int) {
        let visible = tabs.filter { customTabLayout?.group(containing: $0.id)?.isHidden != true }
        guard window?.attachedSheet == nil, NSApp.modalWindow == nil, !visible.isEmpty else { return }
        guard let tab = selectedTab, let index = visible.firstIndex(where: { $0 === tab }) else { select(delta > 0 ? visible[0] : visible[visible.count - 1]); return }
        select(visible[(index + delta + visible.count) % visible.count])
    }
    private func refreshStatus() {
        refreshOperatorState()
        let panes = tabs.flatMap { $0.layout.panes }
        arrangementButton.isEnabled = !tabs.isEmpty || customTabLayout != nil
        for item in arrangementButton.menu?.items.dropFirst() ?? [] {
            item.state = customTabLayout == nil && item.tag == arrangement.rawValue ? .on : .off
        }
        if let pane = selectedTab?.activePane {
            window?.title = "\(tabs.count) 个标签 · \(panes.count) 个终端 | \(pane.title)\(pane.isLogging ? " · 日志记录中" : "")\(pane.isTransferring ? " · 文件传输中" : "") — OShell"
            recordButton.title = pane.isLogging ? "停止记录" : "记录"; recordButton.isEnabled = !pane.ended
        } else { window?.title = tabs.isEmpty ? "OShell" : "\(tabs.count) 个标签 · \(panes.count) 个终端 · 当前无活动标签 — OShell"; recordButton.title = "记录"; recordButton.isEnabled = false }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            menuItem.title = appUpdater.hasPendingInstallation ? "安装已下载的更新…" : "检查更新…"
            return isSecurityUnlocked && NSApp.modalWindow == nil && appUpdater.canCheck
        }
        if menuItem.action == #selector(showUpdatePreferences) { return isSecurityUnlocked && NSApp.modalWindow == nil }
        if menuItem.action == #selector(clearMasterPassword) { return isSecurityUnlocked && configuration.hasMasterPassword && NSApp.modalWindow == nil }
        if [#selector(showPreferences), #selector(showAppearancePreferences)].contains(menuItem.action) { return NSApp.modalWindow == nil && window?.attachedSheet == nil }
        if menuItem.action == #selector(editCurrentSessionProfile) { return canEditCurrentSessionProfile }
        if [#selector(splitVertical), #selector(splitHorizontal)].contains(menuItem.action) { return isSecurityUnlocked && selectedTab != nil }
        if menuItem.action == #selector(showCurrentSessionProperties) { return selectedTab?.activePane.canEditLiveKeepAlive == true }
        if menuItem.action == #selector(toggleSessionLinkBar) { menuItem.state = configuration.sessionLinks.visible ? .on : .off; return true }
        if menuItem.action == #selector(toggleQuickSendBar) { menuItem.state = quickSendBar.isHidden ? .off : .on; return true }
        if menuItem.action == #selector(changeArrangement(_:)) {
            menuItem.state = customTabLayout == nil && menuItem.tag == arrangement.rawValue ? .on : .off
            return !tabs.isEmpty || customTabLayout != nil
        }
        if [#selector(editSession), #selector(deleteSession)].contains(menuItem.action) { return selectedProfile != nil }
        if menuItem.action == #selector(findInTerminal) { return NSApp.keyWindow?.windowController is SessionManager || (selectedTab != nil && NSApp.keyWindow === window) }
        if [#selector(findNextInTerminal), #selector(findPreviousInTerminal)].contains(menuItem.action) { return selectedTab != nil && NSApp.keyWindow === window && window?.attachedSheet == nil && NSApp.modalWindow == nil }
        if [#selector(toggleLogging), #selector(reconnect), #selector(closeTab)].contains(menuItem.action) { return selectedTab != nil }
        if menuItem.action == #selector(refreshCurrentHostIdentity) { return selectedTab?.activePane.canRefreshHostIdentity == true }
        if menuItem.action == #selector(selectNumberedTab(_:)) { return isSecurityUnlocked && menuItem.tag > 0 && menuItem.tag <= numberedTabs.count && NSApp.keyWindow === window && window?.attachedSheet == nil && NSApp.modalWindow == nil }
        if menuItem.action == #selector(chooseTabNumber) { return isSecurityUnlocked && !numberedTabs.isEmpty && NSApp.keyWindow === window && window?.attachedSheet == nil && NSApp.modalWindow == nil }
        if [#selector(nextTab), #selector(previousTab), #selector(lastUsedTab)].contains(menuItem.action) { return tabs.count > 1 && window?.attachedSheet == nil && NSApp.modalWindow == nil }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canQuit() }
    func canQuit(forUpdate: Bool = false) -> Bool {
        let running = tabs.flatMap { $0.layout.panes }.filter(\.hasActiveProcess).count
        let fileOperations = fileWindows.filter(\.hasActiveOperation).count
        if running > 0 || fileOperations > 0 {
            let description = "\(running) 个终端及其文件传输会结束。" + (fileOperations > 0 ? "另有 \(fileOperations) 个文件操作将取消。" : "")
            if !Dialogs.confirm(forUpdate ? "安装更新并重新启动？" : "退出 OShell？", text: description, action: forUpdate ? "关闭会话并更新" : "退出") { return false }
        }
        shutdown(); return true
    }
    func shutdown() { customTabLayout = nil; groupStrips.removeAll(); terminalHost.clearPreview(); idleMemoryReclaimer.cancel(); fileWindows.forEach { $0.close() }; fileWindows = []; syncTargets = []; tabs.flatMap { $0.layout.panes }.forEach { $0.shutdown() }; tabs = []; selectedTab = nil }
    var diagnosticSnapshot: [String: Any] {
        let panes = tabs.flatMap { $0.layout.panes }
        return ["tabs": tabs.count, "panes": panes.count, "composerCreated": loadedComposer != nil, "arrangement": arrangement.title,
                "selectedTabVisible": tabStrip.selectedIsVisible, "renderers": panes.map(\.renderDescription),
                "running": panes.filter(\.hasActiveProcess).count, "scrollback": configuration.preferences.scrollback,
                "receivedBytes": panes.map(\.receivedBytes)]
    }
}
