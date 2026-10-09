// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum Dialogs {
    static func session(_ existing: SessionProfile? = nil, profiles: [SessionProfile] = [], directories: [String] = [], initialDirectory: String = "服务器", kind: SessionKind = .ssh, defaults: SessionDefaults = SessionDefaults()) -> SessionProfile? {
        SessionEditor(existing, profiles: profiles, directories: directories, initialDirectory: initialDirectory, kind: kind, defaults: defaults).run()
    }
    static func preferences(_ current: Preferences, appearanceSelected: Bool = false, updatesSelected: Bool = false, storageView: StorageSettingsView? = nil) -> Preferences? {
        let font = NSPopUpButton()
        TerminalFontCatalog.populate(font, selected: current.fontName)
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
        let trimTrailing = NSButton(checkboxWithTitle: "复制时删除尾部空白", target: nil, action: nil)
        trimTrailing.state = current.copyTrimTrailingWhitespace ? .on : .off; trimTrailing.identifier = .init("settings.copy.trimTrailing")
        let trimLeading = NSButton(checkboxWithTitle: "复制时删除头部空白", target: nil, action: nil)
        trimLeading.state = current.copyTrimLeadingWhitespace ? .on : .off; trimLeading.identifier = .init("settings.copy.trimLeading")
        for control in [trimTrailing, trimLeading] { control.toolTip = "仅清理整段选中文本的边界空白（空格、制表符、换行），保留中间各行缩进；适用于手动复制和选中自动复制。" }
        let trimOptions = NSStackView(views: [trimTrailing, trimLeading]); trimOptions.spacing = 24; trimOptions.alignment = .centerY
        let rightPaste = NSButton(checkboxWithTitle: "鼠标右键粘贴（Shift+右键保留菜单）", target: nil, action: nil); rightPaste.state = current.rightClickPaste ? .on : .off
        let previewPaste = NSButton(checkboxWithTitle: "多行粘贴先预览确认；单行直接粘贴", target: nil, action: nil); previewPaste.state = current.confirmMultilinePaste ? .on : .off
        previewPaste.identifier = .init("settings.paste.preview")
        let shortcutView = ShortcutSettingsView(settings: current.keyboardShortcuts)
        defer { shortcutView.dispose() }
        let appearanceView = AppearanceSettingsView(preferences: current)
        defer { appearanceView.dispose() }
        let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 840, height: 550))
        let basic = GeneralSettingsView(font: font, size: size, history: history, gpu: gpu, input: [zmodem, autoCopy, trimOptions, rightPaste, previewPaste])
        let general = NSTabViewItem(identifier: "general"); general.label = "常规"; general.view = basic; tabs.addTabViewItem(general)
        let colors = NSTabViewItem(identifier: "appearance"); colors.label = "主题与配色"; colors.view = appearanceView; tabs.addTabViewItem(colors)
        let updatesView = UpdateSettingsView(preferences: current)
        let updates = NSTabViewItem(identifier: "updates"); updates.label = "更新"; updates.view = updatesView; tabs.addTabViewItem(updates)
        let shortcuts = NSTabViewItem(identifier: "shortcuts"); shortcuts.label = "快捷键"; shortcuts.view = shortcutView; tabs.addTabViewItem(shortcuts)
        if let storageView {
            let storage = NSTabViewItem(identifier: "storage"); storage.label = "数据与同步"; storage.view = storageView; tabs.addTabViewItem(storage)
        }
        let about = NSTabViewItem(identifier: "about"); about.label = "关于"; about.view = AboutSettingsView(preferences: current); tabs.addTabViewItem(about)
        tabs.selectTabViewItem(at: updatesSelected ? 2 : (appearanceSelected ? 1 : 0))
        let dialog = SettingsWindow(tabs: tabs)
        var prefs = current
        while true {
            guard dialog.runModal() == .OK else { return nil }
            do { prefs = try updatesView.values(updating: appearanceView.values(updating: current)); prefs.keyboardShortcuts = try shortcutView.values(); try storageView?.validateSelection(); break }
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
        prefs.copyTrimLeadingWhitespace = trimLeading.state == .on; prefs.copyTrimTrailingWhitespace = trimTrailing.state == .on
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
