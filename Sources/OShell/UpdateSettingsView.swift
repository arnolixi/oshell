// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class UpdateSettingsView: NSView {
    let repository = NSTextField(), automatic = NSButton(checkboxWithTitle: "每天自动检查更新（安装前仍需确认）", target: nil, action: nil)
    init(preferences: Preferences) {
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        repository.identifier = .init("updates.repository"); automatic.identifier = .init("updates.automatic")
        repository.stringValue = preferences.updateRepository.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "OShellUpdateRepository") as? String ?? "") : preferences.updateRepository
        repository.placeholderString = "owner/repo 或 https://github.com/owner/repo"
        automatic.state = preferences.automaticUpdateChecks ? .on : .off
        let title = NSTextField(labelWithString: "GitHub Releases 更新")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let current = NSTextField(labelWithString: "当前版本：\(version) · 更新版本：\(UpdateFlavor.current.rawValue)")
        current.textColor = .secondaryLabelColor
        let help = NSTextField(wrappingLabelWithString: "填写公开 GitHub 仓库，使用其最新正式 Release 中的更新文件。尚未创建仓库时可留空，程序不会检查网络。\n\n更新包含下载进度和签名校验。安装前会确认关闭活动会话，再退出并重新启动。会话配置与保存密码保留。")
        let stack = NSStackView(views: [title, current, NSTextField(labelWithString: "更新仓库"), repository, automatic, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), repository.widthAnchor.constraint(equalTo: stack.widthAnchor), help.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func values(updating original: Preferences) throws -> Preferences {
        var value = original
        let text = repository.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && automatic.state == .on { throw ModelError.invalid("请先填写更新仓库，或关闭自动检查。") }
        value.updateRepository = text.isEmpty ? "" : try UpdateSource(text).repository
        value.automaticUpdateChecks = automatic.state == .on
        return value
    }
}
