// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Expands only during a transfer; ordinary terminal sessions lose no space.
final class ZmodemProgressView: NSView {
    let title = NSTextField(labelWithString: "")
    let details = NSTextField(labelWithString: "")
    let indicator = NSProgressIndicator()
    let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private lazy var height = heightAnchor.constraint(equalToConstant: 0)
    private(set) var snapshot: ZmodemProgress?
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        details.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        details.textColor = .secondaryLabelColor
        for label in [title, details] { label.lineBreakMode = .byTruncatingMiddle; label.maximumNumberOfLines = 1 }
        indicator.style = .bar; indicator.controlSize = .small
        indicator.minValue = 0; indicator.maxValue = 1
        indicator.setAccessibilityLabel("当前文件传输进度")
        cancelButton.bezelStyle = .inline; cancelButton.controlSize = .small
        cancelButton.setAccessibilityLabel("取消文件传输")
        [title, details, indicator, cancelButton].forEach(addSubview)
        isHidden = true; height.isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 16), cancelWidth: CGFloat = cancelButton.isHidden ? 0 : 44
        title.frame = NSRect(x: 8, y: 38, width: max(0, width - cancelWidth - 4), height: 18)
        cancelButton.frame = NSRect(x: bounds.width - 8 - cancelWidth, y: 38, width: cancelWidth, height: 18)
        indicator.frame = NSRect(x: 8, y: 25, width: width, height: 6)
        details.frame = NSRect(x: 8, y: 5, width: width, height: 16)
    }
    private func show(_ message: String, cancellable: Bool) {
        title.stringValue = message; title.toolTip = message
        cancelButton.isHidden = !cancellable
        isHidden = false; height.constant = 60; needsLayout = true
    }
    func begin(_ message: String) {
        snapshot = nil; details.stringValue = "等待文件信息…"; details.toolTip = nil
        indicator.doubleValue = 0; indicator.isIndeterminate = true; indicator.startAnimation(nil)
        show(message, cancellable: true)
    }
    func update(_ value: ZmodemProgress, direction: TransferDirection) {
        snapshot = value
        show((direction == .upload ? "上传" : "下载") + " · " + (value.filename.isEmpty ? "当前文件" : value.filename), cancellable: true)
        let done = ByteCountFormatter.string(fromByteCount: value.bytes, countStyle: .file)
        let speed = ByteCountFormatter.string(fromByteCount: value.bytesPerSecond, countStyle: .file) + "/s"
        if let fraction = value.fraction, let total = value.total {
            indicator.stopAnimation(nil); indicator.isIndeterminate = false; indicator.doubleValue = fraction
            details.stringValue = "\(Int(floor(fraction * 100)))% · \(done) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · \(speed)"
        } else {
            indicator.isIndeterminate = true; indicator.startAnimation(nil)
            details.stringValue = "已传 \(done) · 总大小待确认 · \(speed)"
        }
        details.toolTip = details.stringValue
    }
    func status(_ message: String, completed: Bool = false) {
        indicator.stopAnimation(nil)
        // Failure/cancel must never turn an unknown or partial transfer into 100%.
        if completed {
            indicator.isIndeterminate = false; indicator.doubleValue = 1
            // The last progress record may arrive after the verified protocol
            // completion. Do not display stale partial counters beside 100%.
            details.stringValue = "100% · 文件传输完成"; details.toolTip = details.stringValue
        }
        show(message, cancellable: false)
    }
    func hide() {
        indicator.stopAnimation(nil); isHidden = true; height.constant = 0; snapshot = nil
    }
}
