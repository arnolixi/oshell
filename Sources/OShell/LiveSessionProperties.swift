// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class LiveSessionProperties: NSObject {
    let alert = PopupAlert()
    let enabled = NSButton(checkboxWithTitle: "终端空闲时发送字符串", target: nil, action: nil)
    let interval = NSTextField(), text = NSTextField()
    let persist = NSButton(checkboxWithTitle: "同时保存到会话配置，供下次连接使用", target: nil, action: nil)
    private let original: KeepAliveSettings, defaults: KeepAliveSettings
    private let canPersist: Bool
    init(profile: SessionProfile, title: String, defaults: KeepAliveSettings, canPersist: Bool) {
        original = profile.keepAlive; self.defaults = defaults; self.canPersist = canPersist
        super.init()
        alert.messageText = "当前会话属性"
        alert.informativeText = "\(title)\n只修改当前终端的空闲保活，无需重连；同一会话的其他连接不受影响。"
        alert.addButton(withTitle: "立即应用"); alert.addButton(withTitle: "取消")
        enabled.state = original.idleEnabled ? .on : .off
        interval.stringValue = String(original.idleInterval); interval.identifier = .init("live.idleInterval")
        text.stringValue = original.idleText
        for field in [interval, text] { field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); field.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        text.identifier = .init("live.idleText")
        enabled.identifier = .init("live.idleEnabled"); enabled.target = self; enabled.action = #selector(updateEnabled)
        persist.identifier = .init("live.persist"); persist.state = canPersist ? .on : .off
        persist.isHidden = !canPersist
        let useDefaults = NSButton(title: "载入全局空闲默认值", target: self, action: #selector(loadDefaults)); useDefaults.bezelStyle = .rounded
        let grid = NSGridView(views: [[NSTextField(labelWithString: ""), enabled], [NSTextField(labelWithString: "空闲间隔（秒）"), interval], [NSTextField(labelWithString: "发送字符串"), text], [NSTextField(labelWithString: ""), useDefaults]])
        grid.column(at: 0).width = 130; grid.column(at: 0).xPlacement = .trailing; grid.column(at: 1).xPlacement = .fill
        grid.rowSpacing = 12; grid.columnSpacing = 12
        let help = NSTextField(wrappingLabelWithString: "间隔范围 1–86400 秒，从应用时重新计时。字符串支持 \\n、\\r、\\t、\\e、\\\\，可用于执行命令。正在编辑命令、输入密码、全屏程序或文件传输时暂停发送。")
        let transport = NSTextField(wrappingLabelWithString: "SSH 协议保活与 TCP KeepAlive 保持本连接启动时的设置；这些参数需在会话管理中修改，并在新连接中生效。")
        for label in [help, transport] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor }
        // Keep fields and explanatory text inside a fixed NSAlert accessory canvas.
        let height: CGFloat = canPersist ? 290 : 260
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: height))
        grid.frame = NSRect(x: 0, y: height - 126, width: 550, height: 126)
        help.frame = NSRect(x: 0, y: height - 192, width: 550, height: 54)
        persist.frame = NSRect(x: 0, y: 65, width: 550, height: 24)
        transport.frame = NSRect(x: 0, y: 0, width: 550, height: 52)
        [grid, help, persist, transport].forEach(content.addSubview)
        alert.accessoryView = content; alert.window.initialFirstResponder = interval; updateEnabled()
    }
    @objc private func updateEnabled() { interval.isEnabled = enabled.state == .on; text.isEnabled = enabled.state == .on }
    @objc func loadDefaults() {
        enabled.state = defaults.idleEnabled ? .on : .off; interval.stringValue = String(defaults.idleInterval); text.stringValue = defaults.idleText
        updateEnabled()
    }
    func values() throws -> KeepAliveSettings {
        var result = original; result.idleEnabled = enabled.state == .on
        result.idleInterval = Int(interval.stringValue) ?? 0; result.idleText = text.stringValue
        try result.validate(); return result
    }
    var savesConfiguration: Bool { canPersist && persist.state == .on }
    func run() -> KeepAliveSettings? {
        while alert.runModal() == .alertFirstButtonReturn {
            do { return try values() } catch { Dialogs.message(error.localizedDescription) }
        }
        return nil
    }
}

extension WorkspaceController {
    @objc func showCurrentSessionProperties() { if let tab = selectedTab { showSessionProperties(tabID: tab.id) } }
    @objc func showTabSessionProperties(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { showSessionProperties(tabID: id) } }
    func showSessionProperties(tabID: UUID) {
        guard let pane = tabs.first(where: { $0.id == tabID })?.activePane, pane.canEditLiveKeepAlive else { return }
        let dialog = LiveSessionProperties(profile: pane.profile, title: pane.title, defaults: configuration.sessionDefaults.keepAlive,
                                           canPersist: configuration.profiles.contains { $0.id == pane.profile.id })
        guard let settings = dialog.run() else { return }
        do { try applyLiveIdleKeepAlive(paneID: pane.id, settings: settings, persist: dialog.savesConfiguration) }
        catch { Dialogs.message(error.localizedDescription) }
    }
    func applyLiveIdleKeepAlive(paneID: UUID, settings: KeepAliveSettings, persist: Bool) throws {
        guard let pane = tabs.flatMap({ $0.layout.panes }).first(where: { $0.id == paneID }), pane.canEditLiveKeepAlive else {
            throw ModelError.invalid("当前 SSH 连接已结束，配置未应用。")
        }
        _ = try pane.profile.keepAlive.replacingIdle(with: settings)
        if persist {
            guard let index = configuration.profiles.firstIndex(where: { $0.id == pane.profile.id }) else {
                throw ModelError.invalid("原会话配置已删除，请取消“同时保存”后重试。")
            }
            var value = configuration
            value.profiles[index].keepAlive = try value.profiles[index].keepAlive.replacingIdle(with: settings)
            guard saveConfiguration(value) else { return }
        }
        try pane.applyIdleKeepAlive(settings)
    }
}
