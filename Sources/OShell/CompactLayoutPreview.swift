// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

/// Development-only viewport measurement and software-rendered layout preview.
enum CompactLayoutPreview {
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_COMPACT_PREVIEW_ROOT"], let window = controller.window else { return }
        let root = URL(fileURLWithPath: path)
        controller.configuration.preferences.metal = false
        window.setContentSize(NSSize(width: 1180, height: 760)); window.appearance = NSAppearance(named: .aqua)
        controller.newLocal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let pane = controller.selectedTab?.activePane, let content = window.contentView else { return }
            pane.receive(Data("\r\nOShell compact workspace\r\nTerminal content area expanded; session information is in the window title.\r\n".utf8))
            content.layoutSubtreeIfNeeded()
            let data: [String: Any] = ["windowTitle": window.title, "contentHeight": content.bounds.height, "terminalHeight": pane.terminal.bounds.height, "terminalWidth": pane.terminal.bounds.width, "rows": pane.terminal.getTerminal().rows, "columns": pane.terminal.getTerminal().cols]
            try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("compact-geometry.json"))
            let view = content.superview ?? content
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let preview = NSImage(size: view.bounds.size); preview.lockFocus()
                NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill()
                bitmap.draw(in: view.bounds); preview.unlockFocus()
                if let tiff = preview.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: root.appendingPathComponent("compact-preview.png"))
                }
            }
            controller.shutdown(); NSApp.terminate(nil)
        }
    }
}
