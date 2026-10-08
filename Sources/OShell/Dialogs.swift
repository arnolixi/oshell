// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum Dialogs {
    static func session(_ existing: SessionProfile? = nil, profiles: [SessionProfile] = [], directories: [String] = [], initialDirectory: String = "服务器", kind: SessionKind = .ssh, defaults: SessionDefaults = SessionDefaults()) -> SessionProfile? {
        SessionEditor(existing, profiles: profiles, directories: directories, initialDirectory: initialDirectory, kind: kind, defaults: defaults).run()
    }
    static func preferences(_ current: Preferences, appearanceSelected: Bool = false, updatesSelected: Bool = false) -> Preferences? {
        let alert = PopupAlert(); alert.messageText = "OShell 设置"
        alert.informativeText = "设置应用于所有已打开的终端，无需重连。界面主题与终端配色可独立选择；较长历史记录会增加内存占用。"
        alert.addButton(withTitle: "应用"); alert.addButton(withTitle: "取消")
        let font = NSPopUpButton(); font.addItem(withTitle: "系统等宽")
        font.lastItem?.representedObject = ""
        for (name, label) in [("Menlo-Regular", "Menlo"), ("Monaco", "Monaco"), ("SFMono-Regular", "SF Mono"),
                              ("JetBrainsMono-Regular", "JetBrains Mono"), ("FiraCode-Regular", "Fira Code"),
                              ("CascadiaCode", "Cascadia Code"), ("CourierNewPSMT", "Courier New")] {
            if NSFont(name: name, size: 13) != nil { font.addItem(withTitle: label); font.lastItem?.representedObject = name }
        }
        if let index = font.itemArray.firstIndex(where: { ($0.representedObject as? String) == current.fontName }) { font.selectItem(at: index) }
        let size = NSPopUpButton(); [11, 12, 13, 14, 15, 16, 18, 20, 24, 26].forEach { size.addItem(withTitle: String($0)) }
        size.selectItem(withTitle: String(Int(current.fontSize)))
        let history = NSPopUpButton(); [500, 1000, 3000, 5000, 10000, 20000].forEach { history.addItem(withTitle: String($0)) }
        history.selectItem(withTitle: String(current.scrollback))
        let gpu = NSButton(checkboxWithTitle: "启用 GPU 加速", target: nil, action: nil); gpu.state = current.metal ? .on : .off
        #if OSHELL_LEGACY
        gpu.state = .off; gpu.isEnabled = false; gpu.title = "旧系统使用标准终端渲染"
        #endif
        let zmodem = NSButton(checkboxWithTitle: "自动识别 rz/sz 文件传输", target: nil, action: nil); zmodem.state = current.autoZmodem ? .on : .off
        let autoCopy = NSButton(checkboxWithTitle: "选中终端文本后自动复制", target: nil, action: nil); autoCopy.state = current.copyOnSelect ? .on : .off
        let rightPaste = NSButton(checkboxWithTitle: "鼠标右键粘贴（Shift+右键保留菜单）", target: nil, action: nil); rightPaste.state = current.rightClickPaste ? .on : .off
        let previewPaste = NSButton(checkboxWithTitle: "多行粘贴先预览确认；单行直接粘贴", target: nil, action: nil); previewPaste.state = current.confirmMultilinePaste ? .on : .off
        let grid = NSGridView(views: [[NSTextField(labelWithString: "终端字体"), font], [NSTextField(labelWithString: "字号"), size], [NSTextField(labelWithString: "历史行数"), history],
                                     [NSTextField(labelWithString: ""), gpu],
                                     [NSTextField(labelWithString: ""), zmodem], [NSTextField(labelWithString: ""), autoCopy], [NSTextField(labelWithString: ""), rightPaste], [NSTextField(labelWithString: ""), previewPaste]])
        grid.rowSpacing = 12; grid.columnSpacing = 18; grid.frame = NSRect(x: 0, y: 0, width: 500, height: 330)
        let shortcutView = ShortcutSettingsView(settings: current.keyboardShortcuts)
        defer { shortcutView.dispose() }
        let appearanceView = AppearanceSettingsView(preferences: current)
        defer { appearanceView.dispose() }
        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 840, height: 550))
        let basic = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        grid.frame = NSRect(x: 18, y: 150, width: 760, height: 330); basic.addSubview(grid)
        let general = NSTabViewItem(identifier: "general"); general.label = "常规"; general.view = basic; tabs.addTabViewItem(general)
        let colors = NSTabViewItem(identifier: "appearance"); colors.label = "主题与配色"; colors.view = appearanceView; tabs.addTabViewItem(colors)
        let updatesView = UpdateSettingsView(preferences: current)
        let updates = NSTabViewItem(identifier: "updates"); updates.label = "更新"; updates.view = updatesView; tabs.addTabViewItem(updates)
        let shortcuts = NSTabViewItem(identifier: "shortcuts"); shortcuts.label = "快捷键"; shortcuts.view = shortcutView; tabs.addTabViewItem(shortcuts)
        tabs.selectTabViewItem(at: updatesSelected ? 2 : (appearanceSelected ? 1 : 0)); alert.accessoryView = tabs
        var prefs = current
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            do { prefs = try updatesView.values(updating: appearanceView.values(updating: current)); prefs.keyboardShortcuts = try shortcutView.values(); break }
            catch { Dialogs.message(error.localizedDescription) }
        }
        prefs.fontName = font.selectedItem?.representedObject as? String ?? ""
        prefs.fontSize = Double(size.titleOfSelectedItem ?? "13") ?? 13
        prefs.scrollback = Int(history.titleOfSelectedItem ?? "3000") ?? 3000
        prefs.metal = gpu.state == .on; prefs.autoZmodem = zmodem.state == .on
        #if OSHELL_LEGACY
        prefs.metal = current.metal
        #endif
        prefs.copyOnSelect = autoCopy.state == .on; prefs.rightClickPaste = rightPaste.state == .on; prefs.confirmMultilinePaste = previewPaste.state == .on
        prefs.clamp(); return prefs
    }
    static func message(_ text: String) {
        let alert = PopupAlert(); alert.messageText = "OShell"; alert.informativeText = text; alert.runModal()
    }
    static func confirm(_ title: String, text: String, action: String) -> Bool {
        let alert = PopupAlert(); alert.messageText = title; alert.informativeText = text
        alert.addButton(withTitle: action); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
