// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

/// Marks an auxiliary window. Esc never closes the main terminal window.
final class PopupWindow: NSWindow {
    override func makeKeyAndOrderFront(_ sender: Any?) {
        appearance = ApplicationAppearance.appearance; super.makeKeyAndOrderFront(sender)
    }
    var onFind: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, NSApp.modalWindow == nil,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f", let onFind { onFind(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// All app-owned modal alerts use the same cancellation path, including when
/// an editable text view would normally consume Esc for completion.
final class PopupAlert: NSAlert {
    @discardableResult override func runModal() -> NSApplication.ModalResponse {
        if let url = Bundle.main.url(forResource: "OShell", withExtension: "icns"), let bundledIcon = NSImage(contentsOf: url) { icon = bundledIcon }
        PopupKeyboard.install()
        let cancel = buttons.first { $0.title == "取消" }
        cancel?.keyEquivalent = "\u{1b}"
        cancel?.keyEquivalentModifierMask = []
        let modalWindow = window
        modalWindow.appearance = ApplicationAppearance.appearance
        let token = PopupKeyboard.register(window: modalWindow) { [weak cancel] in
            if let cancel { cancel.performClick(nil) }
            else { NSApp.abortModal() } // Never activate a sole affirmative button.
        }
        defer {
            PopupKeyboard.unregister(window: modalWindow, token: token)
            modalWindow.orderOut(nil)
        }
        return super.runModal()
    }
}

enum PopupKeyboard {
    private static var monitor: Any?
    private static var observers = [NSObjectProtocol]()
    private static var trackingMenus = Set<ObjectIdentifier>()
    private static var alerts = [ObjectIdentifier: (UUID, () -> Void)]()

    static func isEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == 53 && modifiers.intersection([.command, .option, .control, .shift]).isEmpty
    }
    static func install() {
        guard monitor == nil else { return }
        // Let Esc dismiss a currently tracking menu before its containing window.
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            if let menu = note.object as? NSMenu { trackingMenus.insert(ObjectIdentifier(menu)) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
            if let menu = note.object as? NSMenu { trackingMenus.remove(ObjectIdentifier(menu)) }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isEscape(keyCode: event.keyCode, modifiers: event.modifierFlags),
                  let window = event.window ?? NSApp.keyWindow, window === NSApp.keyWindow else { return event }
            return dismiss(window: window) ? nil : event
        }
    }
    static func register(window: NSWindow, cancellation: @escaping () -> Void) -> UUID {
        let token = UUID(); alerts[ObjectIdentifier(window)] = (token, cancellation); return token
    }
    static func unregister(window: NSWindow, token: UUID) {
        let id = ObjectIdentifier(window)
        if alerts[id]?.0 == token { alerts.removeValue(forKey: id) }
    }
    @discardableResult static func dismiss(window: NSWindow) -> Bool {
        guard trackingMenus.isEmpty, window.attachedSheet == nil else { return false }
        // The shared color panel can be key while an alert remains modal.
        if let panel = window as? NSColorPanel { panel.orderOut(nil); return true }
        if let modal = NSApp.modalWindow, modal !== window { return false }
        if let cancellation = alerts[ObjectIdentifier(window)]?.1 { cancellation(); return true }
        if let panel = window as? NSSavePanel { panel.cancel(nil); return true }
        if window is PopupWindow { window.performClose(nil); return true }
        return false
    }
}
