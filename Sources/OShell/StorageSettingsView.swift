// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class StorageSettingsView: NSView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let scroll = NSScrollView(), document = Document()
    private var contentStack: NSStackView?
    private weak var workspace: WorkspaceController?
    private let location = StorageLocation()
    private let current: URL
    private let status = NSTextField(wrappingLabelWithString: "")
    private var statusCard: SyncStatusView?
    private let davStatus = NSTextField(wrappingLabelWithString: "")
    private let enabled = NSButton(checkboxWithTitle: "启用 WebDAV 同步", target: nil, action: nil)
    private let address = NSTextField(), username = NSTextField(), password = NSSecureTextField()
    private var choice: StorageLocation.Pending?
    private(set) var changed = false
    private var davChanged = false, testing = false, stopDirectorySync = false
    private let isolated: Bool
    init(workspace: WorkspaceController) {
        self.workspace = workspace; current = workspace.store.url.deletingLastPathComponent()
        isolated = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] != nil
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        if !isolated { choice = try? location.pending() }
        func label(_ text: String, title: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: title ? 14 : 12, weight: title ? .semibold : .regular); return field
        }
        let path = label(current.path); path.isSelectable = true; path.identifier = .init("storage.current")
        let setup = NSButton(title: "设置 / 解锁主密码…", target: self, action: #selector(setupMaster))
        let migrate = NSButton(title: "新建同步目录…", target: self, action: #selector(migrate))
        let existing = NSButton(title: "连接已有同步目录…", target: self, action: #selector(useExisting))
        let reveal = NSButton(title: "在 Finder 中打开", target: self, action: #selector(reveal))
        let cancel = NSButton(title: "取消待生效设置", target: self, action: #selector(cancelChange))
        let probe = NSButton(title: "测试 WebDAV 连接", target: self, action: #selector(testConnection))
        for button in [setup, migrate, existing, reveal, cancel, probe] { button.bezelStyle = .rounded }
        migrate.isEnabled = !isolated; existing.isEnabled = !isolated; cancel.isEnabled = !isolated
        let stop = NSButton(title: "停用目录同步", target: self, action: #selector(disableDirectorySync))
        stop.bezelStyle = .rounded; stop.isEnabled = !isolated
        let controls = NSStackView(views: [migrate, existing, cancel, stop]); controls.spacing = 8
        enabled.state = workspace.windowCoordinator?.webDAV.enabled == true ? .on : .off
        enabled.target = self; enabled.action = #selector(davEdited)
        address.placeholderString = "https://服务器/WebDAV/OShell/（请先创建目录）"
        username.placeholderString = "WebDAV 账号"; password.placeholderString = "WebDAV 密码 / 应用专用密码"
        address.identifier = .init("webdav.address"); username.identifier = .init("webdav.username"); password.identifier = .init("webdav.password")
        for field in [address, username, password] { field.delegate = self }
        if let master = PasswordVault.shared.cachedMaster, let settings = try? workspace.windowCoordinator?.webDAV.settings(master: master) {
            address.stringValue = settings.address; username.stringValue = settings.username; password.stringValue = settings.password
        }
        let security = label("iCloud、WebDAV 和自定义目录强制使用主密码。共享配置整体加密，不共享本机解密密钥；启用期间不能清除主密码。")
        security.textColor = .systemOrange
        let help = label("会话和配置始终在本地读写，iCloud / 自定义目录只保存加密同步副本。选择空目录建立同步，或连接已有加密目录；应用后重启启用。旧版直接使用的目录会在启动时迁回本地，并备份原本地文件。\n\n目录不可用或 WebDAV 离线时仍可编辑。启动、切回应用、保存修改及定期检查时同步；同一会话两边修改时逐项确认。iCloud 上传由系统处理，“同步完成”不代表已上传到云端。SSH 信任记录、私钥和下载文件只保存在本机。一次只能启用一种同步方式。")
        let statusCard = SyncStatusView(sync: workspace.windowCoordinator?.webDAV); self.statusCard = statusCard
        let separator = NSBox(); separator.boxType = .separator
        let stack = NSStackView(views: [statusCard, separator, label("共享安全", title: true), security, setup, label("本地数据目录（始终使用）", title: true), path, reveal, label("iCloud / 自定义同步目录", title: true), controls, status, label("WebDAV", title: true), enabled, address, username, password, probe, davStatus, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        scroll.frame = bounds; scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        document.frame = bounds; scroll.documentView = document; addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack); contentStack = stack
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22)])
        for view in [statusCard, separator, security, path, status, address, username, password, davStatus, help] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        updateStatus()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); document.setFrameSize(NSSize(width: scroll.contentSize.width, height: document.frame.height)); document.layoutSubtreeIfNeeded()
        let height = max(scroll.contentSize.height, (contentStack?.fittingSize.height ?? 0) + 44)
        if abs(document.frame.height - height) > 0.5 { document.setFrameSize(NSSize(width: document.frame.width, height: height)) }
    }
    private func master() throws -> String {
        guard let workspace else { throw ModelError.invalid("工作区已关闭。") }
        try SharingProtection.require(workspace.configuration)
        guard let value = PasswordVault.shared.cachedMaster else { throw ModelError.invalid("请先设置 / 解锁主密码。") }
        workspace.store.masterPassword = workspace.store.encryptedStorage ? value : workspace.store.masterPassword
        return value
    }
    @objc private func setupMaster() {
        guard let workspace else { return }
        if !workspace.configuration.hasMasterPassword { workspace.setupMasterPassword() }
        else if let master = PasswordVault.shared.masterForImport(hasSavedPasswords: true) {
            if ConfigurationCredentials.profiles(in: workspace.configuration).contains(where: { $0.encryptedPassword?.localKeyID != nil }) {
                do { _ = try workspace.enableMasterProtection(master) } catch { Dialogs.message(error.localizedDescription) }
            }
        }
        workspace.windowCoordinator?.webDAV.readinessChanged()
        workspace.windowCoordinator?.webDAV.schedule()
        updateStatus()
    }
    private func updateStatus() {
        status.font = .systemFont(ofSize: 12); davStatus.font = .systemFont(ofSize: 12)
        let sharedPath = (try? location.syncDirectory())?.path
        status.stringValue = isolated ? "当前由 OSHELL_DATA_DIR 指定本地测试目录。" : (stopDirectorySync ? "应用后停用目录同步，本地及共享数据均保留。" : "同步目录：" + (sharedPath ?? "未启用")) + (choice.map { "\n下次启动启用：" + $0.path } ?? "")
        statusCard?.refresh()
    }
    @objc private func davEdited() { davChanged = true }
    @objc private func migrate() { choose(.migrate) }
    @objc private func useExisting() { choose(.existing) }
    private func choose(_ mode: StorageLocation.Mode) {
        do {
            let master = try master()
            guard enabled.state != .on else { throw ModelError.invalid("请先停用 WebDAV，再选择 iCloud / 自定义目录。") }
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = mode == .migrate
            panel.title = mode == .migrate ? "选择空的加密同步文件夹" : "选择已有加密同步文件夹"
            let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            panel.directoryURL = FileManager.default.fileExists(atPath: cloud.path) ? cloud : current
            guard panel.runPopupModal() == .OK, let url = panel.url else { return }
            let proposed = StorageLocation.Pending(path: url.resolvingSymlinksInPath().path, mode: mode)
            try location.validate(proposed, master: master)
            if mode == .existing {
                let config = try StorageLocation.validateData(at: url, master: master)
                guard Dialogs.confirm("连接已有加密同步目录？", text: "目标目录有 \(config.profiles.count) 个会话。本地配置会保留；下次启动同步时选择加载共享版本或合并本机会话。", action: "选择此目录") else { return }
            }
            choice = proposed; changed = true; stopDirectorySync = false; updateStatus()
        } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func cancelChange() { choice = nil; stopDirectorySync = false; changed = true; updateStatus() }
    @objc private func disableDirectorySync() { stopDirectorySync = true; choice = nil; changed = true; updateStatus() }
    @objc private func reveal() { NSWorkspace.shared.open(current) }
    private func davSettings() throws -> WebDAVSettings {
        let settings = WebDAVSettings(address: address.stringValue, username: username.stringValue, password: password.stringValue)
        _ = try settings.directory(); return settings
    }
    @objc private func testConnection() {
        guard !testing else { return }
        do {
            _ = try master(); let client = try WebDAVClient(davSettings()); testing = true; davStatus.stringValue = "正在测试…"
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { try client.probe() }
                DispatchQueue.main.async { [weak self] in
                    self?.testing = false
                    self?.workspace?.windowCoordinator?.webDAV.diagnostics.record(.connectionTest, backend: .webDAV, manual: true, error: { if case .failure(let error) = result { return error }; return nil }())
                    switch result { case .success: self?.davStatus.stringValue = "目录响应正常；实际写入会检查服务器版本条件。"
                    case .failure(let error): self?.davStatus.stringValue = error.localizedDescription }
                }
            }
        } catch { davStatus.stringValue = error.localizedDescription }
    }
    func validateSelection() throws {
        if changed, let choice { try location.validate(choice, master: master()) }
        if davChanged, enabled.state == .on {
            _ = try master(); _ = try davSettings()
            let activeDirectory = try location.syncDirectory()
            guard choice == nil, stopDirectorySync || activeDirectory == nil else { throw ModelError.invalid("请先停用目录同步并取消待生效的目录设置，再启用 WebDAV。") }
        }
    }
    func applySelection() throws {
        guard let workspace else { return }
        if changed && stopDirectorySync {
            workspace.windowCoordinator?.webDAV.cancel()
            try location.disableSync()
            if workspace.windowCoordinator?.webDAV.enabled != true { workspace.store.requiresMasterProtection = false }
            workspace.windowCoordinator?.webDAV.directoryConfigurationChanged()
        }
        if davChanged {
            if enabled.state == .on {
                let master = try master(), settings = try davSettings()
                let old = workspace.store.requiresMasterProtection, oldKey = workspace.store.masterPassword
                workspace.store.requiresMasterProtection = true; workspace.store.masterPassword = master
                guard workspace.saveConfiguration(workspace.configuration) else { workspace.store.requiresMasterProtection = old; workspace.store.masterPassword = oldKey; return }
                try workspace.windowCoordinator?.webDAV.configure(settings, master: master)
            } else { try workspace.windowCoordinator?.webDAV.configure(nil, master: PasswordVault.shared.cachedMaster ?? "") }
        }
        if changed && !stopDirectorySync {
            try location.schedule(choice, master: choice == nil ? nil : master())
            Dialogs.message(choice == nil ? "已取消待生效的同步设置。" : "已保存。退出并重新打开后启用目录同步，配置仍保存在本地；当前连接继续运行。")
        }
    }
}
extension StorageSettingsView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { davChanged = true }
}
