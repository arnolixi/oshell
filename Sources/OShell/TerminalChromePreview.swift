// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import QuartzCore
import OShellCore

/// Actual AppKit rendering with fixture text; never connects to a server.
enum TerminalChromePreview {
    static func run(_ workspace: WorkspaceController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { render(workspace) }
    }
    private static func render(_ workspace: WorkspaceController) {
        guard let window = workspace.window, let root = window.contentView,
              let output = ProcessInfo.processInfo.environment["OSHELL_CHROME_OUTPUT"] else { return }
        var checks = [String: Bool]()
        let directory = URL(fileURLWithPath: output).deletingLastPathComponent()
        workspace.configuration.preferences.metal = false
        workspace.configuration.preferences.fontName = "Menlo-Regular"; workspace.configuration.preferences.fontSize = 13
        workspace.configuration.preferences.masterWarningAcknowledged = true
        workspace.configuration.sessionLinks.visible = false
        workspace.refreshMasterWarning(); workspace.sessionLinkBar.isHidden = true; workspace.sessionLinkHeight.constant = 0
        window.appearance = NSAppearance(named: .aqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: 0.94, green: 0.94, blue: 0.94, alpha: 1).cgColor
        window.setContentSize(NSSize(width: 1100, height: 620))
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        func fixture(_ pane: TerminalPane, operations: Bool) {
            let text = operations
                ? "\u{1b}[38;2;134;190;175mops@db-01\u{1b}[0m  ~/logs\r\n$ tail -f application.log\r\n\r\n10:42:01  INFO   Health check completed\r\n10:42:04  INFO   Database connection established\r\n\u{1b}[38;2;226;189;108m10:42:08  WARN   Request latency above threshold\u{1b}[0m\r\n10:42:10  INFO   Worker ready\r\n"
                : "\u{1b}[38;2;134;190;175mdev@api-01\u{1b}[0m  ~/workspace/api\r\n$ git status --short\r\n\u{1b}[38;2;154;193;132m M src/server.ts\r\n M tests/health.test.ts\u{1b}[0m\r\n$ npm run dev\r\n\r\n\u{1b}[38;2;147;184;210m  Local:   http://localhost:3000\u{1b}[0m\r\n  GET /api/health   200   12 ms\r\n  GET /api/status   200    8 ms\r\n\r\n"
            pane.terminal.feed(text: "\u{1b}[0m\u{1b}[2J\u{1b}[H\u{1b}[?25l" + text)
        }
        func snapshot(_ name: String) {
            let previousAppearance = NSAppearance.current
            NSAppearance.current = root.effectiveAppearance
            root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            NSAppearance.current = previousAppearance
            root.layoutSubtreeIfNeeded()
            // Fixture labels only, to make the two preview scenarios readable.
            for strip in allViews(root).compactMap({ $0 as? TabStripView }) {
                for (index, item) in strip.items.enumerated() {
                    item.selectButton.title = index == 0 ? "1  dev-api-01" : "2  ops-db-01"
                    item.preferredWidth = 156
                }
                strip.needsLayout = true
            }
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            let scale = window.backingScaleFactor
            guard let context = CGContext(data: nil, width: Int(root.bounds.width * scale), height: Int(root.bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.scaleBy(x: scale, y: scale)
            root.layer?.render(in: context)
            // SwiftTerm clears default-background pixels in draw(_:); the
            // compositor normally reveals the terminal layer underneath them.
            // Flatten those transparent pixels over that exact terminal color.
            guard let image = context.makeImage(), let opaque = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            opaque.setFillColor(workspace.terminalHost.layer!.backgroundColor!); opaque.fill(imageRect)
            opaque.draw(image, in: imageRect)
            if let flattened = opaque.makeImage(), let png = NSBitmapImageRep(cgImage: flattened).representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent(name + "-review.png"))
                checks[name + "Screenshot"] = true
            }

        }
        workspace.newBlankTab(); let first = workspace.selectedTab!, pane = first.activePane
        workspace.newBlankTab(); workspace.select(first)
        fixture(pane, operations: false)
        checks["singleTerminalHasNoOutlineOrStripe"] = pane.focusStripe.isHidden && pane.view.layer?.borderWidth == 0 && pane.view.layer?.cornerRadius == 0
        checks["hostUsesTerminalBackground"] = workspace.terminalHost.layer?.backgroundColor == pane.view.layer?.backgroundColor
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        snapshot("terminal-chrome-single")
        if ProcessInfo.processInfo.environment["OSHELL_CHROME_KEEP_OPEN"] == "single" { return }
        workspace.splitVertical(); let right = first.activePane
        fixture(pane, operations: false); fixture(right, operations: true); pane.activate()
        checks["onlyActiveSplitHasStripe"] = !pane.focusStripe.isHidden && right.focusStripe.isHidden
        checks["allSplitOutlinesRemoved"] = first.layout.panes.allSatisfy { $0.view.layer?.borderWidth == 0 && $0.view.layer?.cornerRadius == 0 }
        checks["dividerRemainsDraggableNativeSplit"] = first.layout.view is TerminalSplitView && (first.layout.view as? NSSplitView)?.dividerThickness == 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        snapshot("terminal-chrome-split")
        if ProcessInfo.processInfo.environment["OSHELL_CHROME_KEEP_OPEN"] == "split" { return }
        right.activate()
        checks["focusMovesStripeWithoutRestart"] = pane.focusStripe.isHidden && !right.focusStripe.isHidden && first.activePane === right && workspace.tabs.count == 2
        workspace.togglePaneZoom()
        checks["zoomHidesRedundantStripe"] = right.focusStripe.isHidden
        workspace.togglePaneZoom()
        checks["restoreShowsActiveStripe"] = !right.focusStripe.isHidden
        right.closeButton.performClick(nil)
        checks["lastPaneHasNoStripe"] = pane.focusStripe.isHidden && first.layout.panes.count == 1
        let other = workspace.tabs.first { $0 !== first }!
        checks["createGroupThemeFixture"] = workspace.moveTab(other.id, beside: first.id, position: .right)
        fixture(pane, operations: false); fixture(other.activePane, operations: true)
        let terminalBackground = pane.view.layer?.backgroundColor
        func finish() {
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            workspace.shutdown(); NSApp.terminate(nil)
        }
        func verifyEmptyStates(_ index: Int) {
            guard index < 12 else { finish(); return }
            let state = index / 4, theme: InterfaceTheme = index % 2 == 0 ? .dark : .light
            if index == 0 {
                while !workspace.tabs.isEmpty { workspace.select(workspace.tabs[0]); workspace.closeTab() }
                workspace.customTabLayout = nil; workspace.rebuildWorkspace()
            } else if index == 4 || index == 8 {
                let group = TabGroupNode(tabs: [], active: nil); group.isHidden = index == 8
                workspace.customTabLayout = group; workspace.rebuildWorkspace()
            }
            ApplicationAppearance.apply(theme)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                root.layoutSubtreeIfNeeded()
                let surfaces = allViews(workspace.terminalHost).filter { $0 is InterfaceSurfaceView && !($0 is TabStripView) }
                checks["empty\(index)HasInterfaceSurface"] = surfaces.count == 1
                if let surface = surfaces.first, let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) {
                    surface.cacheDisplay(in: surface.bounds, to: bitmap)
                    let color = bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB)
                    checks["empty\(index)Opaque"] = (color?.alphaComponent ?? 0) > 0.99
                    checks["empty\(index)BackgroundMatchesTheme"] = theme == .light ? (color?.redComponent ?? 0) > 0.7 : (color?.redComponent ?? 1) < 0.35
                    let labels = allViews(surface).compactMap { $0 as? NSTextField }
                    let expected = ["连接你的服务器，专注每一条命令。", "此分组暂无会话，可拖入标签", "所有标签组已隐藏，连接继续在后台运行"][state]
                    checks["empty\(index)CorrectState"] = labels.contains { $0.stringValue == expected }
                    checks["empty\(index)ControlsShareAppearance"] = allViews(surface).filter { $0 is NSControl }.allSatisfy { $0.effectiveAppearance.name == surface.effectiveAppearance.name }
                }
                snapshot("terminal-chrome-empty-\(state)-\(theme.rawValue)")
                verifyEmptyStates(index + 1)
            }
        }
        func verifyTheme(_ index: Int) {
            let themes: [InterfaceTheme] = [.dark, .light, .dark, .light]
            guard index < themes.count else { verifyEmptyStates(0); return }
            let theme = themes[index]
            ApplicationAppearance.apply(theme)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let strips = allViews(root).compactMap { $0 as? TabStripView }
                checks["theme\(index)IncludesTwoGroupStrips"] = workspace.groupStrips.count == 2
                for (number, strip) in strips.enumerated() where !strip.isHiddenOrHasHiddenAncestor {
                    strip.layoutSubtreeIfNeeded(); strip.displayIfNeeded()
                    if let bitmap = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) {
                        strip.cacheDisplay(in: strip.bounds, to: bitmap)
                        let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 4)?.usingColorSpace(.sRGB)
                        let light = theme == .light || !ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 10, minorVersion: 14, patchVersion: 0))
                        checks["theme\(index)Strip\(number)OpaqueBackground"] = (color?.alphaComponent ?? 0) > 0.99
                        checks["theme\(index)Strip\(number)MatchesAppearance"] = light ? (color?.redComponent ?? 0) > 0.7 : (color?.redComponent ?? 1) < 0.35
                    } else { checks["theme\(index)Strip\(number)Rendered"] = false }
                }
                checks["theme\(index)PreservesTerminalPalette"] = pane.view.layer?.backgroundColor == terminalBackground
                snapshot("terminal-chrome-groups-\(index)-\(theme.rawValue)")
                verifyTheme(index + 1)
            }
        }
        verifyTheme(0)
        }
        }
    }
}
