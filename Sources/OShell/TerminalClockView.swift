// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// One shared timer for visible terminal clocks, stopped when the last detaches.
final class TerminalClockTicker {
    static let shared = TerminalClockTicker()
    private let views = NSHashTable<TerminalClockView>.weakObjects()
    private var timer: Timer?
    private let formatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian); value.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return value
    }()
    var isRunning: Bool { timer != nil }
    var subscriberCount: Int { views.allObjects.count }
    func text(at date: Date) -> String {
        // Resolve the Mac's current zone each tick, including changes while open.
        formatter.timeZone = .autoupdatingCurrent
        return formatter.string(from: date)
    }
    func update(_ view: TerminalClockView) {
        views.remove(view)
        if view.needsClockUpdates { views.add(view); view.updateText(text(at: Date())) }
        if views.allObjects.isEmpty { timer?.invalidate(); timer = nil }
        else if timer == nil {
            let now = Date().timeIntervalSince1970
            let source = Timer(fire: Date(timeIntervalSince1970: floor(now) + 1), interval: 1, repeats: true) { [weak self] _ in self?.tick() }
            source.tolerance = 0.08; timer = source
            RunLoop.main.add(source, forMode: .common); RunLoop.main.add(source, forMode: .modalPanel)
        }
    }
    private func tick() {
        let text = text(at: Date())
        for view in views.allObjects {
            if !view.needsClockUpdates { views.remove(view) }
            else if view.window?.isMiniaturized == false && !view.isHiddenOrHasHiddenAncestor { view.updateText(text) }
        }
        if views.allObjects.isEmpty { timer?.invalidate(); timer = nil }
    }
}

/// Pure decoration: no PTY writes, no selection, and all pointer events pass through.
final class TerminalClockView: NSView {
    private(set) var enabled = false
    private(set) var position: TerminalClockPosition = .topRight
    private(set) var text = ""
    private var foreground = NSColor.white
    private let clockFont = NSFont.oshellMonospacedSystemFont(ofSize: 12, weight: .medium)
    private var disposed = false
    private weak var terminalArea: NSView?
    private var placement = [NSLayoutConstraint]()
    var needsClockUpdates: Bool { enabled && !disposed && window != nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0.5; isHidden = true; wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); TerminalClockTicker.shared.update(self) }
    func apply(_ preferences: Preferences) {
        guard !disposed else { return }
        enabled = preferences.terminalClockEnabled; position = preferences.terminalClockPosition
        foreground = NSColor(hex: preferences.colorScheme.foreground) ?? .white
        isHidden = !enabled; needsDisplay = true; positionInTerminal()
        TerminalClockTicker.shared.update(self)
    }
    func updateText(_ value: String) {
        guard value != text else { return }
        let old = textRect
        text = value
        setNeedsDisplay(old.union(textRect).insetBy(dx: -2, dy: -2))
    }
    private var attributes: [NSAttributedString.Key: Any] { [.font: clockFont, .foregroundColor: foreground] }
    override var intrinsicContentSize: NSSize {
        let size = ("2000-00-00 00:00:00" as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }
    var textRect: NSRect { bounds }
    func constrain(to terminal: NSView) {
        terminalArea = terminal
        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualTo: terminal.widthAnchor, constant: -24),
            heightAnchor.constraint(equalToConstant: intrinsicContentSize.height)
        ])
        positionInTerminal()
    }
    private func positionInTerminal() {
        guard let terminalArea else { return }
        NSLayoutConstraint.deactivate(placement)
        let horizontal: NSLayoutConstraint
        switch position.column {
        case 0: horizontal = leadingAnchor.constraint(equalTo: terminalArea.leadingAnchor, constant: 12)
        case 1: horizontal = centerXAnchor.constraint(equalTo: terminalArea.centerXAnchor)
        default: horizontal = trailingAnchor.constraint(equalTo: terminalArea.trailingAnchor, constant: -12)
        }
        let vertical: NSLayoutConstraint
        switch position.row {
        case 0: vertical = topAnchor.constraint(equalTo: terminalArea.topAnchor, constant: 12)
        case 1: vertical = centerYAnchor.constraint(equalTo: terminalArea.centerYAnchor)
        default: vertical = bottomAnchor.constraint(equalTo: terminalArea.bottomAnchor, constant: -12)
        }
        placement = [horizontal, vertical]; NSLayoutConstraint.activate(placement)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard enabled, !text.isEmpty else { return }
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }
    func dispose() { disposed = true; enabled = false; isHidden = true; TerminalClockTicker.shared.update(self) }
}

final class TerminalClockSettingsView: NSStackView {
    let enabled = NSButton(checkboxWithTitle: "显示本机时钟（50% 透明）", target: nil, action: nil)
    let position = NSPopUpButton()
    init(_ preferences: Preferences) {
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 8
        enabled.state = preferences.terminalClockEnabled ? .on : .off
        enabled.identifier = .init("settings.clock.enabled")
        enabled.toolTip = "显示当前 Mac 的日期和时间，每秒刷新；不会发送到服务器或写入终端记录。"
        for value in TerminalClockPosition.allCases { position.addItem(withTitle: value.title); position.lastItem?.representedObject = value.rawValue }
        position.selectItem(withTitle: preferences.terminalClockPosition.title)
        position.identifier = .init("settings.clock.position"); position.setAccessibilityLabel("终端时钟位置")
        position.widthAnchor.constraint(equalToConstant: 108).isActive = true
        enabled.target = self; enabled.action = #selector(changed)
        addArrangedSubview(enabled); addArrangedSubview(position); changed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { position.isEnabled = enabled.state == .on }
    func apply(to preferences: inout Preferences) {
        preferences.terminalClockEnabled = enabled.state == .on
        preferences.terminalClockPosition = (position.selectedItem?.representedObject as? String).flatMap(TerminalClockPosition.init(rawValue:)) ?? .topRight
    }
}
