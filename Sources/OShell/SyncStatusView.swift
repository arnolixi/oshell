// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class SyncStatusView: NSView {
    private weak var sync: WebDAVSync?
    private var observer: NSObjectProtocol?
    private let heading = NSTextField(labelWithString: "同步状态")
    private let spinner = NSProgressIndicator()
    private let backend = NSTextField(labelWithString: "")
    private let times = NSTextField(wrappingLabelWithString: "")
    private let pending = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let run = NSButton(title: "关闭设置后同步", target: nil, action: nil)
    private let stop = NSButton(title: "取消本次", target: nil, action: nil)
    init(sync: WebDAVSync?) {
        self.sync = sync
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 258))
        identifier = .init("sync.status.card")
        heading.font = .systemFont(ofSize: 16, weight: .semibold); heading.identifier = .init("sync.status.title")
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true; spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let header = NSStackView(views: [spinner, heading]); header.spacing = 8
        times.identifier = .init("sync.status.times"); pending.identifier = .init("sync.status.pending"); detail.identifier = .init("sync.status.detail")
        for label in [backend, times, pending, detail, hint] { label.font = .systemFont(ofSize: 12) }
        detail.maximumNumberOfLines = 2; detail.lineBreakMode = .byTruncatingTail
        times.maximumNumberOfLines = 2; hint.maximumNumberOfLines = 2
        hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 11)
        run.target = self; run.action = #selector(syncNow); run.identifier = .init("sync.status.run")
        run.toolTip = "关闭设置后使用已保存的配置进行同步；不会应用尚未保存的设置。"
        stop.target = self; stop.action = #selector(cancelSync); stop.identifier = .init("sync.status.cancel")
        let logs = NSButton(title: "查看日志…", target: self, action: #selector(showLogs)); logs.identifier = .init("sync.status.logs")
        let export = NSButton(title: "导出诊断日志…", target: self, action: #selector(exportLogs)); export.identifier = .init("sync.status.export")
        for button in [run, stop, logs, export] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [run, stop, logs, export]); buttons.spacing = 8
        let stack = NSStackView(views: [header, backend, times, pending, detail, buttons, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 258),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            times.widthAnchor.constraint(equalTo: stack.widthAnchor), detail.widthAnchor.constraint(equalTo: stack.widthAnchor), hint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        observer = NotificationCenter.default.addObserver(forName: WebDAVSync.statusDidChange, object: sync, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func date(_ value: Date?) -> String { value.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? "暂无" }
    func refresh() {
        guard let sync else { heading.stringValue = "同步未就绪"; run.isEnabled = false; stop.isEnabled = false; return }
        if !sync.syncEnabled { heading.stringValue = "未启用同步"; heading.textColor = .secondaryLabelColor }
        else if sync.isLocked { heading.stringValue = "已锁定 · 等待主密码"; heading.textColor = .systemOrange }
        else {
            switch sync.phase {
            case .idle: heading.stringValue = "等待检查"; heading.textColor = .labelColor
            case .queued: heading.stringValue = "等待同步"; heading.textColor = .systemOrange
            case .reading: heading.stringValue = "正在读取共享数据"; heading.textColor = .labelColor
            case .writing: heading.stringValue = "正在加密并上传"; heading.textColor = .labelColor
            case .applying: heading.stringValue = "正在应用共享数据"; heading.textColor = .labelColor
            case .success: heading.stringValue = sync.directory == nil ? "同步完成" : "已与本机同步目录对齐"; heading.textColor = .systemGreen
            case .failed: heading.stringValue = "同步失败 · 本地数据已保留"; heading.textColor = .systemOrange
            case .conflict: heading.stringValue = "有待确认的同步冲突"; heading.textColor = .systemOrange
            case .cancelled: heading.stringValue = "本次同步已取消"; heading.textColor = .secondaryLabelColor
            }
        }
        if sync.busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let duration = sync.summary.durationMS.map { String(format: " · 最近耗时 %.1f 秒", Double($0) / 1000) } ?? ""
        backend.stringValue = "方式：" + (sync.syncEnabled ? (sync.directory == nil ? "WebDAV" : "iCloud / 自定义目录") : "仅本地") + duration
        times.stringValue = "最近尝试：\(date(sync.summary.lastAttempt))\n最近成功：\(date(sync.summary.lastSuccess))"
        pending.stringValue = "本地改动：" + (!sync.syncEnabled ? "仅保存在本机" : sync.pendingLocalChanges.map { $0 ? "已保存，等待同步" : "暂无待同步修改" } ?? "待首次比较确认")
        detail.stringValue = sync.recentError.map { "最近错误：" + $0 } ?? sync.status
        detail.toolTip = detail.stringValue; detail.textColor = sync.recentError == nil ? .secondaryLabelColor : .systemOrange
        let schedule = sync.nextCheck.map { "下一次自动检查：" + date($0) + "；设置打开时暂停新检查。" } ?? "自动同步在启动、保存修改、切回应用及定期检查时执行。"
        hint.stringValue = sync.diagnostics.writeIssue ?? (sync.directory == nil ? schedule : "此状态不代表 iCloud 已上传云端；云端进度请在 Finder 查看。\n" + schedule)
        run.isEnabled = sync.syncEnabled && !sync.busy && !sync.manualQueued && !sync.isLocked
        stop.isEnabled = sync.busy || sync.manualQueued
        needsLayout = true
    }
    @objc private func syncNow() { sync?.queueManualSync(); refresh() }
    @objc private func cancelSync() { sync?.cancelCurrent(); refresh() }
    @objc private func exportLogs() {
        guard let sync else { return }
        let panel = NSSavePanel(); panel.title = "导出同步诊断日志"; panel.nameFieldStringValue = "OShell-sync-diagnostics.json"; panel.allowedFileTypes = ["json"]
        guard panel.runPopupModal() == .OK, let url = panel.url else { return }
        do { try PrivateFile.write(sync.diagnostics.export(), to: url) }
        catch { Dialogs.message("无法导出诊断日志：" + error.localizedDescription) }
    }
    @objc private func showLogs() {
        guard let sync else { return }
        let alert = PopupAlert(); alert.messageText = "本地同步诊断日志"
        alert.informativeText = "记录时间、阶段、结果和错误代码；不记录密码、账号、地址、目录路径或会话内容。最多保留 7 天 / 2000 条 / 1 MiB，不参与同步。"
        alert.addButton(withTitle: "关闭"); alert.addButton(withTitle: "导出…"); alert.addButton(withTitle: "清空日志")
        let (scroll, editor) = textEditor("", editable: false); scroll.frame = NSRect(x: 0, y: 0, width: 740, height: 360); alert.accessoryView = scroll
        editor.identifier = .init("sync.logs.content")
        while true {
            let events = sync.diagnostics.entries()
            editor.string = events.isEmpty ? "暂无同步日志。" : events.reversed().map { entry in
                let backend = entry.backend == .directory ? "目录" : (entry.backend == .webDAV ? "WebDAV" : "本地")
                let run = entry.run.map { " · " + String($0.uuidString.prefix(8)) } ?? ""
                let duration = entry.durationMS.map { " · \($0) ms" } ?? ""
                return "\(date(entry.date)) [\(backend)] \(entry.event.title)\(entry.manual ? " · 手动" : "")\(run)\(duration)" + (entry.failure.map { "\n  " + $0.text } ?? "")
            }.joined(separator: "\n")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { exportLogs() }
            else if response == .alertThirdButtonReturn { sync.diagnostics.clear(); refresh() }
            else { break }
        }
    }
}
