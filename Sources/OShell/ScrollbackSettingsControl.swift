// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class ScrollbackSettingsControl: NSStackView, NSTextFieldDelegate {
    let picker = NSPopUpButton()
    let custom = NSTextField()
    let warning = NSTextField(wrappingLabelWithString: "")
    private let unit = NSTextField(labelWithString: "行")
    private static let presets = [500, 1000, 3000, 5000, 10000, 20000]
    init(value: Int) {
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 8
        picker.identifier = .init("settings.history.preset")
        custom.identifier = .init("settings.history.custom")
        warning.identifier = .init("settings.history.warning")
        Self.presets.forEach { picker.addItem(withTitle: String($0)) }
        picker.addItem(withTitle: "自定义…")
        picker.selectItem(at: Self.presets.firstIndex(of: value) ?? Self.presets.count)
        custom.stringValue = String(value); custom.placeholderString = "500–100000"; custom.delegate = self
        custom.setAccessibilityLabel("自定义历史行数")
        picker.target = self; picker.action = #selector(selectionChanged)
        warning.font = .systemFont(ofSize: 11); warning.maximumNumberOfLines = 3
        warning.heightAnchor.constraint(equalToConstant: 44).isActive = true
        picker.widthAnchor.constraint(equalToConstant: 132).isActive = true
        custom.widthAnchor.constraint(equalToConstant: 112).isActive = true
        [picker, custom, unit].forEach(addArrangedSubview)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func value() throws -> Int {
        if picker.indexOfSelectedItem < Self.presets.count, picker.indexOfSelectedItem >= 0 { return Self.presets[picker.indexOfSelectedItem] }
        return try Preferences.parseScrollback(custom.stringValue)
    }
    @objc func selectionChanged() { refresh() }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    private func refresh() {
        let isCustom = picker.indexOfSelectedItem == Self.presets.count
        custom.isHidden = !isCustom; unit.isHidden = !isCustom
        let general = "历史按终端分别保存在内存中；过多行数、多会话或宽窗口会增加内存占用，使搜索和窗口缩放变慢，严重时可能因内存不足退出。"
        let reduction = "降低上限会丢弃较旧的历史；长期留存请使用终端记录文件。"
        if let count = try? value() {
            warning.stringValue = (count > 20000 ? "当前超过 20000 行。" : "") + general + "\n" + reduction
            warning.textColor = count > 20000 ? .systemOrange : .secondaryLabelColor
        } else {
            warning.stringValue = "请输入 500～100000 的整数行数。\n" + general
            warning.textColor = .systemRed
        }
        warning.toolTip = warning.stringValue
    }
}
