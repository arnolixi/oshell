// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum TerminalClockTest {
    static func run(_ workspace: WorkspaceController) {
        guard let window = workspace.window else { return }
        var checks = [String: Bool]()
        func later(_ delay: TimeInterval = 0.15, _ action: @escaping () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func finish() {
            workspace.shutdown()
            checks["lastPaneStopsTimer"] = !TerminalClockTicker.shared.isRunning && TerminalClockTicker.shared.subscriberCount == 0
            if let path = ProcessInfo.processInfo.environment["OSHELL_CLOCK_OUTPUT"] {
                let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
                try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
        later {
            workspace.configuration.preferences.metal = false
            workspace.newBlankTab(); let tab = workspace.selectedTab!, pane = tab.activePane
            checks["disabledByDefaultNoTimer"] = pane.clockView.isHidden && !TerminalClockTicker.shared.isRunning
            later {
                guard let root = NSApp.modalWindow?.contentView,
                      let controls = views(root).compactMap({ $0 as? TerminalClockSettingsView }).first else { return }
                checks["positionDisabledUntilEnabled"] = !controls.position.isEnabled
                controls.enabled.performClick(nil); controls.position.selectItem(withTitle: TerminalClockPosition.bottomRight.title)
                root.layoutSubtreeIfNeeded()
                checks["clockControlsFitSettings"] = controls.position.isEnabled && root.bounds.contains(controls.convert(controls.bounds, to: root))
                views(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
            }
            workspace.showPreferences()
            checks["settingsApplyImmediately"] = pane.clockView.enabled && pane.clockView.position == .bottomRight && TerminalClockTicker.shared.isRunning
            checks["clockPreferencesPersist"] = (try? workspace.store.load().preferences.terminalClockEnabled) == true && (try? workspace.store.load().preferences.terminalClockPosition) == .bottomRight
            let before = pane.clockView.text, originalBuffer = pane.terminal.getTerminal().getBufferAsData()
            later(1.4) {
                checks["updatesEverySecond"] = before != pane.clockView.text
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                checks["usesMacLocalTime"] = [Date(), Date().addingTimeInterval(-1)].contains { formatter.string(from: $0) == pane.clockView.text }
                checks["noTimeWrittenToTerminalBuffer"] = pane.terminal.getTerminal().getBufferAsData() == originalBuffer
                var renderers = [false]
                #if !OSHELL_LEGACY
                renderers.append(true)
                #endif
                for gpu in renderers {
                    var prefs = workspace.configuration.preferences; prefs.metal = gpu
                    for position in TerminalClockPosition.allCases {
                        prefs.terminalClockPosition = position; pane.apply(prefs); window.contentView?.layoutSubtreeIfNeeded()
                        let clock = pane.clockView, rect = pane.terminal.convert(clock.bounds, from: clock), area = pane.terminal.bounds
                        let x = 12 + max(0, area.width - 24 - rect.width) * CGFloat(position.column) / 2
                        let row = pane.terminal.isFlipped ? position.row : 2 - position.row
                        let y = 12 + max(0, area.height - 24 - rect.height) * CGFloat(row) / 2
                        checks["position-\(gpu)-\(position.rawValue)"] = abs(rect.minX - x) < 1 && abs(rect.minY - y) < 1 && area.contains(rect)
                        checks["smallLayerAndHalfOpacity-\(gpu)-\(position.rawValue)"] = clock.bounds.width < 200 && clock.bounds.height < 30 && clock.alphaValue == 0.5
                        let click = clock.convert(NSPoint(x: clock.bounds.midX, y: clock.bounds.midY), to: pane.view)
                        checks["mousePassesThrough-\(gpu)-\(position.rawValue)"] = pane.view.hitTest(pane.view.convert(click, to: pane.view.superview)) === pane.terminal
                    }
                }
                workspace.splitVertical(); let other = tab.activePane
                checks["splitClocksShareOneTicker"] = TerminalClockTicker.shared.subscriberCount == 2 && other.clockView.enabled
                workspace.togglePaneZoom()
                checks["hiddenSplitUnsubscribes"] = TerminalClockTicker.shared.subscriberCount == 1
                workspace.togglePaneZoom()
                checks["restoredSplitResubscribes"] = TerminalClockTicker.shared.subscriberCount == 2
                workspace.newBlankTab(); let next = workspace.selectedTab!
                checks["hiddenTabStopsRefreshing"] = TerminalClockTicker.shared.subscriberCount == 1
                workspace.select(tab); next.activePane.sendManaged(Array("exit\r".utf8))
                checks["switchBackKeepsClocks"] = TerminalClockTicker.shared.subscriberCount == 2
                later {
                    guard let root = NSApp.modalWindow?.contentView, let controls = views(root).compactMap({ $0 as? TerminalClockSettingsView }).first else { return }
                    controls.enabled.performClick(nil)
                    _ = PopupKeyboard.dismiss(window: NSApp.modalWindow!)
                }
                workspace.showPreferences()
                checks["cancelDoesNotDisableClocks"] = pane.clockView.enabled && other.clockView.enabled
                var value = workspace.configuration; value.preferences.terminalClockEnabled = false
                checks["disableSaves"] = workspace.saveConfiguration(value)
                checks["disableStopsSharedTicker"] = !TerminalClockTicker.shared.isRunning && pane.clockView.isHidden && other.clockView.isHidden
                value.preferences.terminalClockEnabled = true; _ = workspace.saveConfiguration(value)
                finish()
            }
        }
    }
}
