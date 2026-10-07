// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

extension WorkspaceController {
    func configureSessionLinkBar() {
        sessionLinkBar.onOpen = { [weak self] target, view in
            guard let self else { return }
            switch target {
            case .link(let id): self.openSessionLink(id)
            case .folder(let folder): self.sessionLinkMenu(folder: folder).popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
            }
        }
        sessionLinkBar.makeContextMenu = { [weak self] in self?.sessionLinkContextMenu($0) }
    }
    func rebuildSessionLinkBar() {
        let links = configuration.sessionLinks
        let entries: [SessionLinkBar.Entry] = links.allFolders.filter { SessionDirectory.parent($0).isEmpty }.map {
            .init(target: .folder($0), title: $0, detail: "快捷链接文件夹：" + $0)
        } + links.entries.filter { $0.folder.isEmpty }.map {
            .init(target: .link($0.id), title: $0.name, detail: linkDetail($0))
        }
        sessionLinkBar.update(entries, menu: sessionLinkMenu(folder: ""))
        sessionLinkBar.isHidden = !links.visible; sessionLinkHeight?.constant = links.visible ? 30 : 0
    }
    private func linkDetail(_ link: SessionLink) -> String {
        guard let profile = configuration.profiles.first(where: { $0.id == link.profileID }) else { return link.name }
        return "\(link.name) · \(profile.kind.title)\n\(profile.username)@\(profile.host):\(profile.port)\n点击新建连接 · 右键管理链接"
    }
    @objc func toggleSessionLinkBar() {
        var value = configuration; value.sessionLinks.visible.toggle(); _ = saveConfiguration(value)
    }
    func sessionTabContextMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let tab = tabs.first { $0.id == id }
        for (title, action, enabled, hint) in [
            ("新建空白标签页", #selector(newBlankFromTab(_:)), true, "打开本机工具提示符，不自动连接"),
            ("复制会话", #selector(copyTabSession(_:)), tab != nil, "使用相同配置建立独立连接，按需重新认证"),
            ("复制 SSH 渠道", #selector(copyTabSSHChannel(_:)), tab.map(canCopySSHChannel) ?? false, "在已认证的 SSH 连接上新开终端渠道，不重复认证")
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = id; item.isEnabled = enabled; item.toolTip = hint
        }
        menu.addItem(.separator())
        let add = menu.addItem(withTitle: "添加到快捷链接…", action: #selector(addTabSessionLink(_:)), keyEquivalent: "")
        add.target = self; add.representedObject = id; add.isEnabled = tabs.contains { $0.id == id }
        let properties = menu.addItem(withTitle: "当前会话属性…", action: #selector(showTabSessionProperties(_:)), keyEquivalent: "")
        properties.target = self; properties.representedObject = id
        properties.isEnabled = tabs.first { $0.id == id }?.activePane.canEditLiveKeepAlive == true
        menu.addItem(.separator())
        for (index, title) in ["垂直分割（左右）", "水平分割（上下）"].enumerated() {
            let item = menu.addItem(withTitle: title, action: #selector(splitTabFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; item.tag = index; item.isEnabled = canSplitTab(id)
            item.toolTip = "移动现有标签到独立分区，保持会话连接"
        }
        let merge = menu.addItem(withTitle: "合并为单组选项卡", action: #selector(mergeTabGroups), keyEquivalent: "")
        merge.target = self; merge.isEnabled = customTabLayout != nil || arrangement != .tabs
        let arrangementItem = menu.addItem(withTitle: "排列", action: nil, keyEquivalent: "")
        let arrangements = NSMenu(); arrangements.autoenablesItems = false
        for mode in TabArrangement.allCases {
            let item = arrangements.addItem(withTitle: mode.title, action: #selector(changeArrangement(_:)), keyEquivalent: "")
            item.target = self; item.tag = mode.rawValue; item.toolTip = mode.hint
            item.state = customTabLayout == nil && arrangement == mode ? .on : .off
        }
        arrangementItem.submenu = arrangements
        return menu
    }
    @objc private func addTabSessionLink(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }; addSessionLink(tabID: id)
    }
    @objc private func addCurrentSessionLink() { if let tab = selectedTab { addSessionLink(tabID: tab.id) } }
    func addSessionLink(tabID: UUID) {
        guard let pane = tabs.first(where: { $0.id == tabID })?.activePane else { return }
        var profile = configuration.profiles.first { $0.id == pane.profile.id }
        if profile == nil {
            if pane.profile.kind == .local { profile = pane.profile }
            else {
                // Review unsaved/USM settings using the normal credential editor.
                // The pane's one-time password and nested shell commands are not copied.
                profile = Dialogs.session(pane.profile, profiles: credentialProfiles, directories: SessionDirectory.all(configuration), defaults: configuration.sessionDefaults)
            }
        }
        guard let profile else { return }
        let alert = PopupAlert(); alert.messageText = "添加到快捷链接"
        alert.informativeText = "链接到会话“\(profile.name)”，点击后使用该会话配置新建连接。"
        alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        let name = NSTextField(string: profile.name), folder = NSPopUpButton()
        folder.addItems(withTitles: ["快捷链接栏（平铺）"] + configuration.sessionLinks.allFolders)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "链接名称"), name], [NSTextField(labelWithString: "保存位置"), folder]])
        grid.columnSpacing = 14; grid.rowSpacing = 12; grid.frame = NSRect(x: 0, y: 0, width: 440, height: 70)
        alert.accessoryView = grid; alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 1024, !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { Dialogs.message("请输入有效链接名称（最多 1 KB）。"); return }
        var value = configuration
        if !value.profiles.contains(where: { $0.id == profile.id }) { value.profiles.append(profile) }
        value.sessionLinks.add(profileID: profile.id, name: title, folder: folder.indexOfSelectedItem > 0 ? folder.titleOfSelectedItem ?? "" : "")
        _ = saveConfiguration(value)
    }
    func openSessionLink(_ id: UUID) {
        guard let link = configuration.sessionLinks.entries.first(where: { $0.id == id }),
              let profile = configuration.profiles.first(where: { $0.id == link.profileID }) else { return }
        open(profile)
    }
    @objc private func connectSessionLink(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { openSessionLink(id) } }
    func sessionLinkMenu(folder: String) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for child in configuration.sessionLinks.allFolders where SessionDirectory.parent(child) == folder {
            let item = menu.addItem(withTitle: String(child.split(separator: "/").last ?? ""), action: nil, keyEquivalent: "")
            item.image = NSImage(oshellSymbolName: "folder", accessibilityDescription: nil); item.submenu = sessionLinkMenu(folder: child)
        }
        for link in configuration.sessionLinks.entries where link.folder == folder {
            let item = menu.addItem(withTitle: link.name, action: #selector(connectSessionLink(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = link.id; item.toolTip = linkDetail(link)
        }
        if menu.items.isEmpty { let item = menu.addItem(withTitle: "暂无快捷链接", action: nil, keyEquivalent: ""); item.isEnabled = false }
        return menu
    }
    func sessionLinkContextMenu(_ target: SessionLinkBar.Target?) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ object: Any? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = object
        }
        var folder = ""
        switch target {
        case .link(let id):
            add("新建连接", #selector(connectSessionLink(_:)), id)
            add("重命名链接…", #selector(renameSessionLink(_:)), id)
            let move = menu.addItem(withTitle: "移动到", action: nil, keyEquivalent: "")
            move.submenu = moveSessionLinkMenu(id)
            add("从快捷链接移除", #selector(removeSessionLink(_:)), id)
        case .folder(let path):
            folder = path
            add("重命名文件夹…", #selector(renameLinkFolder(_:)), path)
            add("删除快捷链接文件夹…", #selector(removeLinkFolder(_:)), path)
        case nil: break
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        add("添加当前会话链接…", #selector(addCurrentSessionLink)); menu.items.last?.isEnabled = selectedTab != nil
        add("新建文件夹…", #selector(newLinkFolder(_:)), folder)
        let management = NSMenu(); management.autoenablesItems = false
        for path in configuration.sessionLinks.allFolders where folder.isEmpty || (path != folder && SessionDirectory.contains(path, in: folder)) {
            let item = management.addItem(withTitle: path, action: nil, keyEquivalent: ""), actions = NSMenu(); actions.autoenablesItems = false
            item.image = NSImage(oshellSymbolName: "folder", accessibilityDescription: nil)
            for (title, action) in [("重命名文件夹…", #selector(renameLinkFolder(_:))), ("新建子文件夹…", #selector(newLinkFolder(_:))), ("删除快捷链接文件夹…", #selector(removeLinkFolder(_:)))] {
                let actionItem = actions.addItem(withTitle: title, action: action, keyEquivalent: ""); actionItem.target = self; actionItem.representedObject = path
            }
            item.submenu = actions
        }
        for link in configuration.sessionLinks.entries where folder.isEmpty || SessionDirectory.contains(link.folder, in: folder) {
            let item = management.addItem(withTitle: (link.folder.isEmpty ? "" : link.folder + "/") + link.name, action: nil, keyEquivalent: "")
            // Only link-specific operations here; avoid recursively building management menus.
            let actions = NSMenu(); actions.autoenablesItems = false
            for (title, action) in [("重命名链接…", #selector(renameSessionLink(_:))), ("从快捷链接移除", #selector(removeSessionLink(_:)))] {
                let actionItem = actions.addItem(withTitle: title, action: action, keyEquivalent: ""); actionItem.target = self; actionItem.representedObject = link.id
            }
            let move = actions.addItem(withTitle: "移动到", action: nil, keyEquivalent: "")
            move.submenu = moveSessionLinkMenu(link.id)
            item.submenu = actions
        }
        if !management.items.isEmpty { let item = menu.addItem(withTitle: "管理链接", action: nil, keyEquivalent: ""); item.submenu = management }
        menu.addItem(.separator()); add("隐藏快捷链接栏", #selector(toggleSessionLinkBar))
        return menu
    }
    private func moveSessionLinkMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for path in [""] + configuration.sessionLinks.allFolders {
            let item = menu.addItem(withTitle: path.isEmpty ? "快捷链接栏（平铺）" : path, action: #selector(moveSessionLink(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = [id.uuidString, path]
            item.state = configuration.sessionLinks.entries.first { $0.id == id }?.folder == path ? .on : .off
        }
        return menu
    }
    private func linkName(_ title: String, value: String = "") -> String? {
        let alert = PopupAlert(); alert.messageText = title; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 400, height: 26)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 1024, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { Dialogs.message("请输入有效名称（最多 1 KB）。"); return nil }
        return text
    }
    @objc private func renameSessionLink(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let index = configuration.sessionLinks.entries.firstIndex(where: { $0.id == id }),
              let name = linkName("重命名快捷链接", value: configuration.sessionLinks.entries[index].name) else { return }
        var value = configuration; value.sessionLinks.entries[index].name = name; _ = saveConfiguration(value)
    }
    @objc private func removeSessionLink(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        var value = configuration; value.sessionLinks.entries.removeAll { $0.id == id }; _ = saveConfiguration(value)
    }
    @objc private func moveSessionLink(_ sender: NSMenuItem) {
        guard let args = sender.representedObject as? [String], args.count == 2, let id = UUID(uuidString: args[0]),
              let index = configuration.sessionLinks.entries.firstIndex(where: { $0.id == id }) else { return }
        var value = configuration; value.sessionLinks.entries[index].folder = args[1]; _ = saveConfiguration(value)
    }
    @objc private func newLinkFolder(_ sender: NSMenuItem) {
        guard let name = linkName("新建快捷链接文件夹（可用 / 建立多级目录）") else { return }
        let parent = sender.representedObject as? String ?? ""
        let folder = SessionDirectory.normalize(parent.isEmpty ? name : parent + "/" + name)
        guard !folder.isEmpty, !configuration.sessionLinks.allFolders.contains(folder) else { Dialogs.message("文件夹名称无效或已存在。"); return }
        var value = configuration; value.sessionLinks.folders.append(folder); _ = saveConfiguration(value)
    }
    @objc private func renameLinkFolder(_ sender: NSMenuItem) {
        guard let old = sender.representedObject as? String, let name = linkName("重命名快捷链接文件夹", value: old) else { return }
        do { var value = configuration; try value.sessionLinks.renameFolder(old, to: name); _ = saveConfiguration(value) }
        catch { Dialogs.message(error.localizedDescription) }
    }
    @objc private func removeLinkFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String,
              Dialogs.confirm("删除快捷链接文件夹“\(folder)”？", text: "只移除该文件夹及其中的快捷链接，会话管理中的配置保留。", action: "删除") else { return }
        var value = configuration; value.sessionLinks.removeFolder(folder); _ = saveConfiguration(value)
    }
}
