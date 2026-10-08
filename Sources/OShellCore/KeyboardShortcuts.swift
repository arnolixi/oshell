// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public struct KeyboardShortcut: Codable, Equatable, Hashable {
    // Stable app-owned mask, independent of NSEvent/Carbon bit layouts.
    public static let command = 1, option = 2, control = 4, shift = 8
    public var keyCode: UInt16
    public var modifiers: Int
    public init(_ code: UInt16, _ modifiers: Int) { keyCode = code; self.modifiers = modifiers }
    public var key: ShortcutKey? { ShortcutKey.all.first { $0.code == keyCode } }
    public var display: String {
        (modifiers & Self.control != 0 ? "⌃" : "") + (modifiers & Self.option != 0 ? "⌥" : "") + (modifiers & Self.shift != 0 ? "⇧" : "") + (modifiers & Self.command != 0 ? "⌘" : "") + (key?.label ?? "?")
    }
    public var isValid: Bool { key != nil && modifiers >= 0 && modifiers < 16 && (modifiers & 7 != 0 || key?.isFunction == true) }
}
public struct ShortcutKey {
    public let code: UInt16, label: String, equivalent: String
    public var isFunction: Bool { label.hasPrefix("F") && Int(label.dropFirst()) != nil }
    public static let all: [ShortcutKey] = {
        let letters: [(UInt16, String)] = [(0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),(38,"J"),(40,"K"),(37,"L"),(46,"M"),(45,"N"),(31,"O"),(35,"P"),(12,"Q"),(15,"R"),(1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z"), (29,"0"),(18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9"), (43,","),(47,"."),(44,"/"),(41,";"),(39,"'"),(33,"["),(30,"]"),(42,"\\"),(27,"-"),(24,"="),(50,"`")]
        var keys = letters.map { Self(code: $0.0, label: $0.1, equivalent: $0.1.lowercased()) }
        keys += [(UInt16(48), "⇥", "\t"), (36,"↩","\r"), (49,"空格"," "), (51,"⌫","\u{7f}"), (53,"Esc","\u{1b}"), (123,"←","\u{f702}"), (124,"→","\u{f703}"), (125,"↓","\u{f701}"), (126,"↑","\u{f700}"), (115,"Home","\u{f729}"), (119,"End","\u{f72b}"), (116,"Page Up","\u{f72c}"), (121,"Page Down","\u{f72d}")].map { Self(code: $0.0, label: $0.1, equivalent: $0.2) }
        for (index, code) in [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90].enumerated() {
            keys.append(Self(code: UInt16(code), label: "F\(index + 1)", equivalent: String(UnicodeScalar(0xf704 + index)!)))
        }
        return keys
    }()
}
public enum ShortcutAction: String, Codable, CaseIterable {
    case newWindow, settings, sessionManager, connectSelected, newSession, newBlank, local, currentProperties, liveProperties, defaults, importSessions, exportSessions
    case reconnect, closePane, closeTab, copy, paste, selectAll, find, findNext, findPrevious
    case splitVertical, splitHorizontal, logging, nextTab, previousTab, recentTab
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9, tabNumber
    case newGroup, showGroups, arrangeTabs, arrangeHorizontal, arrangeVertical, arrangeTiled
    case links, quickSend, focusQuickSend, composer, syncInput, stopSync, files, quickCommands, highlights, appearance, hide, quit, minimize
    public var title: String {
        if let number { return "跳到当前分组标签 \(number)" }
        switch self {
        case .newWindow: return "新建窗口"
        case .settings: return "App 设置"
        case .sessionManager: return "会话管理"
        case .connectSelected: return "连接会话管理中的选中会话"
        case .newSession: return "新建会话配置"
        case .newBlank: return "新建空白标签"
        case .local: return "新建本地终端"
        case .currentProperties: return "当前会话完整属性"
        case .liveProperties: return "当前会话空闲保活"
        case .defaults: return "默认会话属性"
        case .importSessions: return "导入会话"
        case .exportSessions: return "导出全部会话"
        case .reconnect: return "重新连接"
        case .closePane: return "关闭当前分屏"
        case .closeTab: return "关闭当前标签"
        case .copy: return "复制"
        case .paste: return "粘贴"
        case .selectAll: return "全选"
        case .find: return "搜索"
        case .findNext: return "下一个匹配"
        case .findPrevious: return "上一个匹配"
        case .splitVertical: return "新建左右分屏"
        case .splitHorizontal: return "新建上下分屏"
        case .logging: return "开始 / 停止日志记录"
        case .nextTab: return "下一个标签"
        case .previousTab: return "上一个标签"
        case .recentTab: return "切回最近使用的标签"
        case .tabNumber: return "输入标签编号"
        case .newGroup: return "新建标签组"
        case .showGroups: return "显示全部标签组"
        case .arrangeTabs: return "选项卡排列"
        case .arrangeHorizontal: return "水平排列"
        case .arrangeVertical: return "垂直排列"
        case .arrangeTiled: return "瓷砖排列"
        case .links: return "显示 / 隐藏链接栏"
        case .quickSend: return "显示 / 隐藏快速发送栏"
        case .focusQuickSend: return "定位快速发送栏"
        case .composer: return "显示 / 隐藏撰写窗"
        case .syncInput: return "配置同步输入"
        case .stopSync: return "停止同步输入"
        case .files: return "文件管理"
        case .quickCommands: return "快速命令管理器"
        case .highlights: return "突出显示集"
        case .appearance: return "主题与配色"
        case .hide: return "隐藏 OShell"
        case .quit: return "退出 OShell"
        case .minimize: return "最小化窗口"
        default: return rawValue
        }
    }
    public var number: Int? { rawValue.hasPrefix("tab") ? Int(rawValue.dropFirst(3)) : nil }
    public var defaults: [KeyboardShortcut] {
        let cmd = KeyboardShortcut.command, shift = KeyboardShortcut.shift, ctrl = KeyboardShortcut.control
        if let number, let key = ShortcutKey.all.first(where: { $0.label == String(number) }) { return [.init(key.code, cmd)] }
        switch self {
        case .newWindow: return [.init(45,cmd|shift)]
        case .settings: return [.init(43,cmd)]
        case .sessionManager: return [.init(31,cmd|shift)]
        case .connectSelected: return [.init(36,cmd)]
        case .newSession: return [.init(45,cmd)]
        case .local: return [.init(17,cmd)]
        case .reconnect: return [.init(15,cmd|shift)]
        case .closePane: return [.init(13,cmd)]
        case .closeTab: return [.init(13,cmd|shift)]
        case .copy: return [.init(8,cmd)]
        case .paste: return [.init(9,cmd)]
        case .selectAll: return [.init(0,cmd)]
        case .find: return [.init(3,cmd)]
        case .findNext: return [.init(5,cmd)]
        case .findPrevious: return [.init(5,cmd|shift)]
        case .splitVertical: return [.init(2,cmd)]
        case .splitHorizontal: return [.init(2,cmd|shift)]
        case .logging: return [.init(37,cmd|shift)]
        case .nextTab: return [.init(48,ctrl), .init(30,cmd|shift)]
        case .previousTab: return [.init(48,ctrl|shift), .init(33,cmd|shift)]
        case .recentTab: return [.init(50,ctrl)]
        case .tabNumber: return [.init(29,cmd)]
        case .focusQuickSend: return [.init(40,cmd|shift)]
        case .composer: return [.init(34,cmd|shift)]
        case .hide: return [.init(4,cmd)]
        case .quit: return [.init(12,cmd)]
        case .minimize: return [.init(46,cmd)]
        default: return []
        }
    }
}
public struct ShortcutOverride: Codable, Equatable {
    public var shortcut: KeyboardShortcut?
    public init(_ shortcut: KeyboardShortcut?) { self.shortcut = shortcut }
}
public struct KeyboardShortcuts: Codable, Equatable {
    public var overrides: [String: ShortcutOverride] = [:]
    public init() {}
    public func bindings(for action: ShortcutAction) -> [KeyboardShortcut] {
        if let override = overrides[action.rawValue] { return override.shortcut.map { [$0] } ?? [] }
        return action.defaults
    }
    public func action(for shortcut: KeyboardShortcut) -> ShortcutAction? {
        let matches = ShortcutAction.allCases.filter { bindings(for: $0).contains(shortcut) }
        return matches.count == 1 ? matches[0] : nil
    }
    public func conflict(_ shortcut: KeyboardShortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && bindings(for: $0).contains(shortcut) }
    }
    public func validate() throws {
        for action in ShortcutAction.allCases {
            for shortcut in bindings(for: action) {
                guard shortcut.isValid else { throw ModelError.invalid("“\(action.title)”的快捷键无效，请重新指定。") }
                if let other = conflict(shortcut, excluding: action) { throw ModelError.invalid("“\(action.title)”与“\(other.title)”使用相同快捷键 \(shortcut.display)。") }
            }
        }
    }
}
