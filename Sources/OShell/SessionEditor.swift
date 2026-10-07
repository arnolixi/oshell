// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class SessionEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var profile: SessionProfile
    private let original: SessionProfile?
    private let directoryBase: String
    private let defaults: SessionDefaults
    private let profiles: [SessionProfile]
    private let alert = PopupAlert()
    private let pages = NSTabView()
    private let name = NSTextField(), directory = NSComboBox(), host = NSTextField(), port = NSTextField(), user = NSTextField(), key = NSTextField()
    private let password = NSSecureTextField(), remember = NSButton(checkboxWithTitle: "保存密码", target: nil, action: nil)
    private let passwordProtection = NSPopUpButton(), proxyProtection = NSPopUpButton()
    private let proxyKind = NSPopUpButton(), proxyHost = NSTextField(), proxyPort = NSTextField(), proxyUser = NSTextField(), proxyPassword = NSSecureTextField()
    private let proxyRemember = NSButton(checkboxWithTitle: "保存代理密码", target: nil, action: nil)
    private let legacy = NSButton(checkboxWithTitle: "兼容 CentOS 6 / 旧版 SSH 服务", target: nil, action: nil)
    private let alive = NSButton(checkboxWithTitle: "发送 SSH 保持活动消息", target: nil, action: nil)
    private let interval = NSTextField(), missed = NSTextField()
    private let tcp = NSButton(checkboxWithTitle: "启用 TCP KeepAlive", target: nil, action: nil)
    private let idle = NSButton(checkboxWithTitle: "终端空闲时发送字符串", target: nil, action: nil)
    private let idleInterval = NSTextField(), idleText = NSTextField()
    private let quick = NSButton(checkboxWithTitle: "显示在顶部快捷连接菜单", target: nil, action: nil)
    private let activeProbe = NSButton(checkboxWithTitle: "允许主动探测主机名/IP（可能写入命令历史）", target: nil, action: nil)
    var dialog: PopupAlert { alert }
    var pageTitles: [String] { pages.tabViewItems.map(\.label) }
    private let tunnels = NSTableView()
    let protocolKind = NSPopUpButton()
    private let remoteDirectory = NSTextField()
    private var allPages = [NSTabViewItem]()
    private var lastKind: SessionKind = .ssh
    init(_ existing: SessionProfile?, profiles: [SessionProfile], directories: [String], initialDirectory: String, kind: SessionKind = .ssh, defaults: SessionDefaults = SessionDefaults()) {
        directoryBase = existing?.group ?? initialDirectory
        original = existing; profile = existing ?? defaults.makeProfile(kind: kind, directory: initialDirectory); self.profiles = profiles; self.defaults = defaults
        lastKind = profile.kind
        super.init()
        alert.messageText = existing == nil ? "新建会话" : "会话属性"
        alert.informativeText = "配置在下次新建连接时生效。密码可由 OShell 本机自动加密，无需主密码；也可选择主密码保护。不使用系统钥匙串。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        name.stringValue = profile.name; directory.stringValue = SessionDirectory.display(profile.group)
        name.identifier = .init("session.name"); host.identifier = .init("session.host"); port.identifier = .init("session.port")
        user.identifier = .init("session.user"); interval.identifier = .init("session.keepAlive.interval")
        directory.identifier = .init("session.directory")
        directory.addItems(withObjectValues: ["/"] + Array(Set(directories.map(SessionDirectory.display))).filter { $0 != "/" }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }); directory.completes = true
        host.stringValue = profile.host; host.placeholderString = "主机地址或 SSH 配置别名"
        port.stringValue = String(profile.port); user.stringValue = profile.username
        user.placeholderString = "留空使用 SSH 默认用户"
        key.stringValue = profile.identityFile; key.placeholderString = "可选，例如 ~/.ssh/id_rsa"
        password.placeholderString = profile.encryptedPassword == nil ? "留空则在连接时输入" : "已保存；留空保留，填写新值替换"
        remember.state = profile.encryptedPassword == nil ? .off : .on
        password.identifier = .init("session.password"); remember.identifier = .init("session.remember")
        passwordProtection.identifier = .init("session.passwordProtection"); proxyProtection.identifier = .init("session.proxyProtection")
        for popup in [passwordProtection, proxyProtection] { popup.addItems(withTitles: PasswordProtection.allCases.map(\.title)) }
        passwordProtection.selectItem(at: profile.encryptedPassword != nil && profile.encryptedPassword?.localKeyID == nil ? 1 : 0)
        proxyProtection.selectItem(at: profile.proxy.encryptedPassword != nil && profile.proxy.encryptedPassword?.localKeyID == nil ? 1 : 0)
        remember.target = self; remember.action = #selector(passwordStorageChanged)
        proxyRemember.target = self; proxyRemember.action = #selector(passwordStorageChanged)
        if PasswordVault.shared.masterProtectionEnabled {
            for popup in [passwordProtection, proxyProtection] {
                popup.selectItem(at: 1); popup.autoenablesItems = false; popup.item(at: 0)?.isEnabled = false
            }
        }
        let passwordStorage = NSStackView(views: [remember, passwordProtection]); passwordStorage.spacing = 8
        let proxyStorage = NSStackView(views: [proxyRemember, proxyProtection]); proxyStorage.spacing = 8
        directory.placeholderString = "/生产/机房/数据库"
        directory.toolTip = "会话管理目录；/ 表示根目录。相对路径基于 \(SessionDirectory.display(directoryBase))，支持 . 和 ..；这不是服务器的文件目录。"
        legacy.state = profile.legacySSH ? .on : .off
        protocolKind.addItems(withTitles: ["SSH", "SFTP", "FTP"])
        protocolKind.selectItem(at: [.ssh, .sftp, .ftp].firstIndex(of: profile.kind) ?? 0)
        protocolKind.target = self; protocolKind.action = #selector(protocolChanged)
        remoteDirectory.stringValue = profile.initialDirectory
        addPage("连接", rows: [("协议", protocolKind), ("名称", name), ("目录", directory), ("主机", host), ("端口", port), ("用户名", user), ("私钥", key), ("密码", password), ("密码保存", passwordStorage), ("文件初始目录", remoteDirectory), ("兼容性", legacy)], note: "本机自动加密的密文和随机密钥均由 OShell 保存在数据目录，复制整个目录可能同时带走密钥。主密码模式保护更强。旧密码留空切换时需解锁一次，也可重新填写会话密码。")
        proxyKind.addItems(withTitles: ProxyKind.allCases.map(\.title)); proxyKind.selectItem(at: ProxyKind.allCases.firstIndex(of: profile.proxy.kind)!)
        proxyHost.stringValue = profile.proxy.host; proxyPort.stringValue = String(profile.proxy.port); proxyUser.stringValue = profile.proxy.username
        proxyPassword.placeholderString = profile.proxy.encryptedPassword == nil ? "不保存则在连接时询问" : "已保存；留空保留，填写新值替换"
        proxyRemember.state = profile.proxy.encryptedPassword == nil ? .off : .on
        let oldJump = NSTextField(string: profile.jumpHost); oldJump.placeholderString = "兼容旧配置，如 user@bastion:22；与上方代理互斥"
        oldJump.identifier = .init("legacy-jump")
        addPage("代理", rows: [("类型", proxyKind), ("主机", proxyHost), ("端口", proxyPort), ("用户名", proxyUser), ("密码", proxyPassword), ("密码保存", proxyStorage), ("旧跳板机", oldJump)], note: "SOCKS4 使用本地 IPv4 解析，SOCKS4A / SOCKS5 由代理解析域名。HTTP 使用 CONNECT（可选 Basic 认证）。SSH 跳板机使用系统 SSH 配置、Agent 或交互认证。")
        proxyKind.target = self; proxyKind.action = #selector(proxyChanged)
        let tunnelPage = NSView()
        let note = label("连接建立后自动应用启用的转发规则，可配置本地、远程及动态 SOCKS 转发。")
        for (id, title, width) in [("kind", "类型", 110.0), ("source", "监听地址", 160.0), ("target", "目标", 180.0), ("note", "说明", 130.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; tunnels.addTableColumn(column)
        }
        tunnels.rowHeight = 28; tunnels.delegate = self; tunnels.dataSource = self
        tunnels.target = self; tunnels.doubleAction = #selector(editTunnel)
        let scroll = NSScrollView(); scroll.documentView = tunnels; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let buttons = NSStackView(views: [button("添加规则", #selector(addTunnel)), button("编辑", #selector(editTunnel)), button("删除", #selector(removeTunnel))]); buttons.spacing = 8
        [note, scroll, buttons].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; tunnelPage.addSubview($0) }
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: tunnelPage.topAnchor, constant: 18), note.leadingAnchor.constraint(equalTo: tunnelPage.leadingAnchor, constant: 18), note.trailingAnchor.constraint(equalTo: tunnelPage.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 18), scroll.leadingAnchor.constraint(equalTo: note.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: note.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10), buttons.leadingAnchor.constraint(equalTo: note.leadingAnchor), buttons.bottomAnchor.constraint(equalTo: tunnelPage.bottomAnchor, constant: -18)])
        let tunnelItem = NSTabViewItem(identifier: "隧道"); tunnelItem.label = "隧道"; tunnelItem.view = tunnelPage; pages.addTabViewItem(tunnelItem)
        alive.state = profile.keepAlive.enabled ? .on : .off; interval.stringValue = String(profile.keepAlive.interval); missed.stringValue = String(profile.keepAlive.maxMissed)
        tcp.state = profile.keepAlive.tcp ? .on : .off; idle.state = profile.keepAlive.idleEnabled ? .on : .off
        idleInterval.stringValue = String(profile.keepAlive.idleInterval); idleText.stringValue = profile.keepAlive.idleText
        addPage("保持活动", rows: [("默认配置", button("使用全局默认", #selector(useDefaultKeepAlive))), ("", alive), ("间隔（秒）", interval), ("最大未响应次数", missed), ("", tcp), ("", idle), ("空闲间隔（秒）", idleInterval), ("发送字符串", idleText)], note: "空闲字符串在登录成功后发送到终端，可执行命令；支持 \\n、\\r、\\t、\\e、\\\\。输入、输出或文件传输期间不发送。SSH 保活消息不会输入命令。默认属性可在会话管理右键菜单中配置；点击使用默认后需保存才生效。")
        [alive, idle].forEach { $0.target = self; $0.action = #selector(keepAliveChanged) }
        quick.state = profile.quickConnect ? .on : .off
        activeProbe.state = profile.activeHostProbe ? .on : .off
        addPage("标签与快捷连接", rows: [("", quick), ("", activeProbe)], note: "默认优先接收 Shell 集成上报；未配置脚本时，自动降级为提示符、OSC 0/2 标题和 OSC 7 目录识别，不输入探测命令。无法确认 IP 时显示待识别，不沿用上一层地址。仅在明确需要旧探测方式时勾选此项；收到集成上报后，该连接停止后续主动探测。")
        pages.frame = NSRect(x: 0, y: 0, width: 680, height: 500); alert.accessoryView = pages
        alert.window.initialFirstResponder = name
        allPages = pages.tabViewItems; protocolChanged(); proxyChanged(); keepAliveChanged()
    }
    private func label(_ text: String) -> NSTextField { let view = NSTextField(wrappingLabelWithString: text); view.font = .systemFont(ofSize: 11); view.textColor = .secondaryLabelColor; return view }
    private func button(_ text: String, _ action: Selector) -> NSButton { let b = NSButton(title: text, target: self, action: action); b.bezelStyle = .rounded; return b }
    private func addPage(_ title: String, rows: [(String, NSView)], note: String? = nil) {
        let view = NSView(), grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing; grid.column(at: 0).width = 140; grid.column(at: 1).xPlacement = .fill; grid.rowSpacing = 12; grid.columnSpacing = 14
        for (_, control) in rows {
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        grid.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(grid)
        NSLayoutConstraint.activate([grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 22), grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18), grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)])
        if let note {
            let text = label(note); text.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(text)
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: grid.leadingAnchor), text.trailingAnchor.constraint(equalTo: grid.trailingAnchor), text.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20)])
        }
        let item = NSTabViewItem(identifier: title); item.label = title; item.view = view; pages.addTabViewItem(item)
    }
    @objc func protocolChanged() {
        let kind: SessionKind = [.ssh, .sftp, .ftp][protocolKind.indexOfSelectedItem]
        if kind != lastKind {
            if original == nil {
                let before = defaults.makeProfile(kind: lastKind, directory: ""), next = defaults.makeProfile(kind: kind, directory: "")
                if port.stringValue == String(before.port) { port.stringValue = String(next.port) }
                if user.stringValue == before.username { user.stringValue = next.username }
                if remoteDirectory.stringValue == before.initialDirectory { remoteDirectory.stringValue = next.initialDirectory }
            } else {
                if port.stringValue == String(lastKind == .ftp ? 21 : 22) { port.stringValue = String(kind == .ftp ? 21 : 22) }
                if kind == .ftp && remoteDirectory.stringValue == "." { remoteDirectory.stringValue = "/" }
            }
        }
        lastKind = kind
        key.isEnabled = kind.usesSSH; legacy.isEnabled = kind.usesSSH
        activeProbe.isEnabled = kind.usesSSH
        host.placeholderString = kind == .ftp ? "FTP 主机地址" : "主机地址或 SSH 配置别名"
        user.placeholderString = kind == .ftp ? "例如 anonymous" : "留空使用 SSH 默认用户"
        for item in pages.tabViewItems { pages.removeTabViewItem(item) }
        for item in allPages {
            if kind == .ftp && ["代理", "隧道", "保持活动"].contains(item.label) { continue }
            if kind == .sftp && item.label == "隧道" { continue }
            pages.addTabViewItem(item)
        }
        keepAliveChanged()
    }
    @objc private func proxyChanged() {
        let kind = ProxyKind.allCases[proxyKind.indexOfSelectedItem]
        [proxyHost, proxyPort, proxyUser].forEach { $0.isEnabled = kind != .none }
        proxyPassword.isEnabled = kind == .socks5 || kind == .http; proxyRemember.isEnabled = proxyPassword.isEnabled
        passwordStorageChanged()
    }
    @objc private func passwordStorageChanged() {
        passwordProtection.isEnabled = remember.state == .on
        proxyProtection.isEnabled = proxyRemember.isEnabled && proxyRemember.state == .on
    }
    @objc private func keepAliveChanged() {
        interval.isEnabled = alive.state == .on; missed.isEnabled = alive.state == .on
        idle.isEnabled = lastKind == .ssh
        idleInterval.isEnabled = lastKind == .ssh && idle.state == .on; idleText.isEnabled = idleInterval.isEnabled
    }
    @objc func useDefaultKeepAlive() {
        let value = defaults.keepAlive
        alive.state = value.enabled ? .on : .off; interval.stringValue = String(value.interval); missed.stringValue = String(value.maxMissed)
        tcp.state = value.tcp ? .on : .off; idle.state = lastKind == .ssh && value.idleEnabled ? .on : .off
        idleInterval.stringValue = String(value.idleInterval); idleText.stringValue = value.idleText
        keepAliveChanged()
    }
    func run() -> SessionProfile? {
        while alert.runModal() == .alertFirstButtonReturn {
            profile.kind = [.ssh, .sftp, .ftp][protocolKind.indexOfSelectedItem]
            profile.initialDirectory = remoteDirectory.stringValue
            profile.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); profile.port = Int(port.stringValue) ?? 0
            profile.username = user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); profile.identityFile = key.stringValue
            func find(_ view: NSView) -> NSTextField? { if view.identifier?.rawValue == "legacy-jump" { return view as? NSTextField }; return view.subviews.compactMap(find).first }
            profile.jumpHost = pages.tabViewItems.compactMap { $0.view.flatMap(find) }.first?.stringValue ?? ""
            profile.proxy.kind = ProxyKind.allCases[proxyKind.indexOfSelectedItem]
            profile.proxy.host = proxyHost.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.proxy.port = Int(proxyPort.stringValue) ?? 0; profile.proxy.username = proxyUser.stringValue
            profile.legacySSH = legacy.state == .on
            profile.keepAlive.enabled = alive.state == .on; profile.keepAlive.interval = Int(interval.stringValue) ?? 0; profile.keepAlive.maxMissed = Int(missed.stringValue) ?? 0
            profile.keepAlive.tcp = tcp.state == .on; profile.keepAlive.idleEnabled = profile.kind == .ssh && idle.state == .on
            profile.keepAlive.idleInterval = Int(idleInterval.stringValue) ?? 0; profile.keepAlive.idleText = idleText.stringValue
            profile.quickConnect = quick.state == .on
            profile.activeHostProbe = activeProbe.state == .on
            if profile.kind == .ftp {
                profile.identityFile = ""; profile.jumpHost = ""; profile.proxy = ProxySettings(); profile.tunnels = []; profile.legacySSH = false; profile.keepAlive = KeepAliveSettings()
            }
            do {
                profile.group = try SessionDirectory.resolvePath(directory.stringValue, relativeTo: directoryBase)
                directory.stringValue = SessionDirectory.display(profile.group)
                try profile.validate()
                let known = profiles + profiles.filter { $0.proxy.encryptedPassword != nil }.map { $0.proxy.credentialProfile }
                func protect(_ input: String, destination: SessionProfile, old: SessionProfile?, selection: NSPopUpButton, explicitIdentity: Bool) throws -> EncryptedPassword? {
                    let mode = PasswordProtection.allCases[selection.indexOfSelectedItem]
                    var secret = input
                    var identity: SSHIdentity? = explicitIdentity ? SSHIdentity(host: destination.host, user: destination.username, port: destination.port) : nil
                    if secret.isEmpty {
                        guard let old, let envelope = old.encryptedPassword else { throw ModelError.invalid("请填写要保存的密码。"); }
                        guard old.host == destination.host, old.port == destination.port, old.username == destination.username,
                              old.kind.usesSSH == destination.kind.usesSSH else { throw ModelError.invalid("连接目标已改变，请重新输入密码或取消保存。"); }
                        let oldMode: PasswordProtection = envelope.localKeyID == nil ? .master : .local
                        if mode == oldMode { return PasswordVault.shared.currentCredential(old).encryptedPassword }
                        let resolved = try identity ?? SSHIdentity.resolve(destination)
                        guard resolved == envelope.identity else { throw ModelError.invalid("SSH 配置解析出的目标已改变，请重新输入密码。"); }
                        identity = resolved
                        guard let value = try PasswordVault.shared.readSavedPassword(old) else { return nil }; secret = value
                    }
                    return try PasswordVault.shared.protect(secret, profile: destination, knownProfiles: known, protection: mode,
                        identity: identity)
                }
                if remember.state == .on {
                    guard let encrypted = try protect(password.stringValue, destination: profile, old: original, selection: passwordProtection, explicitIdentity: profile.kind == .ftp) else { continue }
                    profile.encryptedPassword = encrypted
                } else { profile.encryptedPassword = nil }
                if profile.proxy.supportsPassword && proxyRemember.state == .on {
                    guard !profile.proxy.username.isEmpty else { throw ModelError.invalid("保存代理密码时请填写代理用户名。"); }
                    guard let encrypted = try protect(proxyPassword.stringValue, destination: profile.proxy.credentialProfile, old: original?.proxy.credentialProfile, selection: proxyProtection, explicitIdentity: true) else { continue }
                    profile.proxy.encryptedPassword = encrypted
                } else { profile.proxy.encryptedPassword = nil }
                password.stringValue = ""; proxyPassword.stringValue = ""; return profile
            } catch { Dialogs.message(error.localizedDescription) }
        }
        password.stringValue = ""; proxyPassword.stringValue = ""; return nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { profile.tunnels.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = profile.tunnels[row], text: String
        switch tableColumn?.identifier.rawValue {
        case "kind": text = (rule.enabled ? "" : "已停用 · ") + rule.kind.title
        case "source": text = "\(rule.bindHost):\(rule.listenPort)"
        case "target": text = rule.kind == .dynamic ? "SOCKS4/5" : "\(rule.destinationHost):\(rule.destinationPort)"
        default: text = rule.note
        }
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingMiddle; return label
    }
    @objc private func addTunnel() { if let rule = Self.tunnel(nil) { profile.tunnels.append(rule); tunnels.reloadData() } }
    @objc private func editTunnel() { let row = tunnels.selectedRow; if profile.tunnels.indices.contains(row), let rule = Self.tunnel(profile.tunnels[row]) { profile.tunnels[row] = rule; tunnels.reloadData() } }
    @objc private func removeTunnel() { let row = tunnels.selectedRow; if profile.tunnels.indices.contains(row) { profile.tunnels.remove(at: row); tunnels.reloadData() } }
    private static func tunnel(_ original: TunnelRule?) -> TunnelRule? {
        var rule = original ?? TunnelRule()
        let alert = PopupAlert(); alert.messageText = "隧道转发规则"; alert.informativeText = "监听地址默认 127.0.0.1；使用 0.0.0.0 会允许其他主机访问。远程监听还受服务器 GatewayPorts 设置限制。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let enabled = NSButton(checkboxWithTitle: "启用此规则", target: nil, action: nil); enabled.state = rule.enabled ? .on : .off
        let kind = NSPopUpButton(); kind.addItems(withTitles: TunnelKind.allCases.map(\.title)); kind.selectItem(at: TunnelKind.allCases.firstIndex(of: rule.kind)!)
        let bind = NSTextField(string: rule.bindHost), port = NSTextField(string: String(rule.listenPort)), destination = NSTextField(string: rule.destinationHost), targetPort = NSTextField(string: String(rule.destinationPort)), note = NSTextField(string: rule.note)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "类型"), kind], [NSTextField(labelWithString: "监听地址"), bind], [NSTextField(labelWithString: "监听端口"), port], [NSTextField(labelWithString: "目标主机（动态模式忽略）"), destination], [NSTextField(labelWithString: "目标端口"), targetPort], [NSTextField(labelWithString: "说明"), note], [NSTextField(labelWithString: ""), enabled]])
        grid.rowSpacing = 12; grid.columnSpacing = 12; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 0).width = 180; grid.column(at: 1).xPlacement = .fill; grid.frame = NSRect(x: 0, y: 0, width: 550, height: 260); alert.accessoryView = grid
        while alert.runModal() == .alertFirstButtonReturn {
            rule.kind = TunnelKind.allCases[kind.indexOfSelectedItem]; rule.enabled = enabled.state == .on
            rule.bindHost = bind.stringValue; rule.listenPort = Int(port.stringValue) ?? 0; rule.destinationHost = destination.stringValue; rule.destinationPort = Int(targetPort.stringValue) ?? 0; rule.note = note.stringValue
            do { try rule.validate(); return rule } catch { Dialogs.message(error.localizedDescription) }
        }
        return nil
    }
}
