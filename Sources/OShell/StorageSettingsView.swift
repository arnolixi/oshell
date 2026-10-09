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
    private let davStatus = NSTextField(wrappingLabelWithString: "")
    private let enabled = NSButton(checkboxWithTitle: "启用 WebDAV 同步", target: nil, action: nil)
    private let address = NSTextField(), username = NSTextField(), password = NSSecureTextField()
    private var choice: StorageLocation.Pending?
    private(set) var changed = false
    private var davChanged = false, testing = false
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
        let migrate = NSButton(title: "迁移当前数据到…", target: self, action: #selector(migrate))
        let existing = NSButton(title: "使用已有数据目录…", target: self, action: #selector(useExisting))
        let reveal = NSButton(title: "在 Finder 中打开", target: self, action: #selector(reveal))
        let cancel = NSButton(title: "取消待生效的切换", target: self, action: #selector(cancelChange))
        let probe = NSButton(title: "测试 WebDAV 连接", target: self, action: #selector(testConnection))
        for button in [setup, migrate, existing, reveal, cancel, probe] { button.bezelStyle = .rounded }
        migrate.isEnabled = !isolated; existing.isEnabled = !isolated; cancel.isEnabled = !isolated
        let controls = NSStackView(views: [migrate, existing, reveal, cancel]); controls.spacing = 8
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
        let help = label("目录共享：选择空目录迁移，或加载已有的加密目录，应用后下次启动生效；原目录保留。其他 Mac 使用同一主密码。SSH 主机信任记录、私钥与下载文件保留在各 Mac 本地。\n\nWebDAV：采用本地加密副本，联网后自动检查并同步；离线可继续使用。首次连接已有远端时需选择加载或合并。使用 HTTPS 和版本条件写入；同一会话两边修改时逐项确认。请勿同时启用 iCloud 文件夹与 WebDAV 两种同步方式。")
        let stack = NSStackView(views: [label("共享安全", title: true), security, setup, label("iCloud / 自定义数据目录", title: true), path, controls, status, label("WebDAV", title: true), enabled, address, username, password, probe, davStatus, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        scroll.frame = bounds; scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        document.frame = bounds; scroll.documentView = document; addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack); contentStack = stack
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22)])
        for view in [security, path, status, address, username, password, davStatus, help] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
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
        updateStatus()
    }
    private func updateStatus() {
        status.font = .systemFont(ofSize: 12); davStatus.font = .systemFont(ofSize: 12)
        status.stringValue = isolated ? "当前由 OSHELL_DATA_DIR 指定目录。" : choice.map { "下次启动：" + $0.path } ?? "没有待生效的目录切换。"
        davStatus.stringValue = workspace?.windowCoordinator?.webDAV.status ?? "尚未配置"
    }
    @objc private func davEdited() { davChanged = true }
    @objc private func migrate() { choose(.migrate) }
    @objc private func useExisting() { choose(.existing) }
    private func choose(_ mode: StorageLocation.Mode) {
        do {
            let master = try master()
            guard enabled.state != .on else { throw ModelError.invalid("请先停用 WebDAV，再选择 iCloud / 自定义目录。") }
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = mode == .migrate
            panel.title = mode == .migrate ? "选择空的数据文件夹" : "选择已有加密数据文件夹"
            let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            panel.directoryURL = FileManager.default.fileExists(atPath: cloud.path) ? cloud : current
            guard panel.runPopupModal() == .OK, let url = panel.url else { return }
            let proposed = StorageLocation.Pending(path: url.resolvingSymlinksInPath().path, mode: mode)
            try location.validate(proposed, master: master)
            if mode == .existing {
                let config = try StorageLocation.validateData(at: url, master: master)
                guard Dialogs.confirm("加载已有加密数据？", text: "目标目录有 \(config.profiles.count) 个会话。下次启动使用这份数据，当前目录保留。", action: "选择此目录") else { return }
            }
            choice = proposed; changed = true; updateStatus()
        } catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func cancelChange() { choice = nil; changed = true; updateStatus() }
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
            guard current.standardizedFileURL == WebDAVSync.root.standardizedFileURL, choice == nil else { throw ModelError.invalid("WebDAV 使用默认本地目录作为加密副本。请先切回默认本地数据目录，并取消待生效的目录迁移。") }
        }
    }
    func applySelection() throws {
        guard let workspace else { return }
        if davChanged {
            if enabled.state == .on {
                let master = try master(), settings = try davSettings()
                let old = workspace.store.requiresMasterProtection, oldKey = workspace.store.masterPassword
                workspace.store.requiresMasterProtection = true; workspace.store.masterPassword = master
                guard workspace.saveConfiguration(workspace.configuration) else { workspace.store.requiresMasterProtection = old; workspace.store.masterPassword = oldKey; return }
                try workspace.windowCoordinator?.webDAV.configure(settings, master: master)
            } else { try workspace.windowCoordinator?.webDAV.configure(nil, master: PasswordVault.shared.cachedMaster ?? "") }
        }
        if changed {
            try location.schedule(choice, master: choice == nil ? nil : master())
            Dialogs.message(choice == nil ? "已取消目录切换。" : "已保存。退出并重新打开后完成加密迁移；当前连接继续运行。")
        }
    }
}
extension StorageSettingsView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { davChanged = true }
}
