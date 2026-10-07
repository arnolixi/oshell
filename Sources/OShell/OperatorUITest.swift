// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum OperatorUITest {
    static func run(_ controller: WorkspaceController) {
        var results = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func geometry(_ window: NSWindow) -> Bool {
            guard let root = window.contentView else { return false }
            root.layoutSubtreeIfNeeded()
            return descendants(root).filter { $0 is NSButton || $0 is NSSearchField || $0 is NSPopUpButton }.allSatisfy {
                if $0.isHiddenOrHasHiddenAncestor { return true }
                let frame = $0.convert($0.bounds, to: root)
                return frame.width > 0 && frame.height > 0 && root.bounds.insetBy(dx: -1, dy: -1).contains(frame)
            }
        }
        controller.newLocal()
        controller.newLocal()
        controller.syncTargets = Set(controller.inputPanes.map(\.id)); controller.refreshOperatorState()
        controller.showQuickCommands(); controller.showHighlights()
        let fileWindow = RemoteFileWindow(workspace: controller); fileWindow.showWindow(nil)
        for size in [NSSize(width: 1180, height: 760), NSSize(width: 760, height: 460)] {
            controller.window?.setContentSize(size)
            results["mainControls\(Int(size.width))"] = geometry(controller.window!)
            if let root = controller.window?.contentView {
                let syncFrame = controller.syncIndicator.convert(controller.syncIndicator.bounds, to: root)
                let stopFrame = controller.stopSyncButton.convert(controller.stopSyncButton.bounds, to: root)
                results["syncControlsAtTop\(Int(size.width))"] = !controller.syncIndicator.isHidden && syncFrame.minY > root.bounds.height - 42 && stopFrame.width >= 22 && stopFrame.minY > root.bounds.height - 42
                let sendFrame = controller.quickSendBar.convert(controller.quickSendBar.bounds, to: root)
                results["noFooterBelowQuickSend\(Int(size.width))"] = abs(sendFrame.minY) < 1
            }
            controller.toggleComposer()
            controller.composer.editor.string = "hostname\nwhoami"
            results["composerVisible\(Int(size.width))"] = geometry(controller.window!) && controller.composer.editor.bounds.width > 100 && controller.composer.editor.bounds.height > 20
            controller.toggleComposer()
            results["composerHidden\(Int(size.width))"] = controller.composer.isHidden && controller.composerHeight.constant == 0
        }
        if let window = controller.commandManager?.window {
            window.setContentSize(NSSize(width: 650, height: 350)); results["quickManagerControls"] = geometry(window)
        }
        if let window = controller.highlightManager?.window {
            window.setContentSize(NSSize(width: 740, height: 380)); results["highlightManagerControls"] = geometry(window)
        }
        if let window = fileWindow.window {
            window.setContentSize(NSSize(width: 800, height: 450)); results["fileManagerControls"] = geometry(window)
            let titles = descendants(window.contentView!).compactMap { ($0 as? NSButton)?.title }
            results["fileActionsPresent"] = titles.contains("上传…") && titles.contains("下载…") && titles.contains("SCP…")
        }
        let output = ProcessInfo.processInfo.environment["OSHELL_OPERATOR_UI_OUTPUT"] ?? "/tmp/oshell-operator-ui-result.json"
        let report: [String: Any] = ["passed": results.values.allSatisfy { $0 }, "checks": results]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        print(report); fileWindow.close(); controller.commandManager?.close(); controller.highlightManager?.close(); controller.shutdown(); NSApp.terminate(nil)
    }
}
