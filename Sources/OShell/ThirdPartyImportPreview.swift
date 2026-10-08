// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class ThirdPartyImportPreview: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let report: ThirdPartySessionReport
    let table = NSTableView()
    init(_ report: ThirdPartySessionReport) {
        self.report = report
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 340))
        table.delegate = self; table.dataSource = self; table.rowHeight = 27; table.usesAlternatingRowBackgroundColors = true
        for (key, title, width) in [("name", "名称", 150.0), ("folder", "目录", 155.0), ("protocol", "协议", 60.0), ("host", "主机", 170.0), ("port", "端口", 55.0), ("user", "用户名", 110.0), ("password", "保存的密码", 100.0)] {
            let column = NSTableColumn(identifier: .init(key)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.identifier = .init("import.external.sessions")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        let (notes, text) = textEditor(report.notes, editable: false); text.identifier = .init("import.external.notes")
        let tabs = NSTabView(frame: bounds); tabs.autoresizingMask = [.width, .height]
        let sessions = NSTabViewItem(identifier: "sessions"); sessions.label = "可导入会话（\(report.profiles.count)）"; sessions.view = scroll
        let details = NSTabViewItem(identifier: "issues"); details.label = "迁移提示 / 跳过原因（\(report.issues.count)）"; details.view = notes
        tabs.addTabViewItem(sessions); tabs.addTabViewItem(details); addSubview(tabs)
        if report.profiles.isEmpty { tabs.selectTabViewItem(details) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfRows(in tableView: NSTableView) -> Int { report.profiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let profile = report.profiles[row], value: String
        switch tableColumn?.identifier.rawValue {
        case "name": value = profile.name
        case "folder": value = SessionDirectory.display(profile.group)
        case "protocol": value = profile.kind.title
        case "host": value = profile.host
        case "port": value = String(profile.port)
        case "password": value = report.xshellPasswords[profile.id] == nil ? "未提供" : "已检测（待校验）"
        default: value = profile.username.isEmpty ? "（未提供）" : profile.username
        }
        let cell = NSTableCellView(), label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label); cell.textField = label; cell.toolTip = value
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}
