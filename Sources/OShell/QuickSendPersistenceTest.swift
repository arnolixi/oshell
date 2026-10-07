// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum QuickSendPersistenceTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func modal(_ action: @escaping (NSWindow) -> Void) {
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in if let window = NSApp.modalWindow { action(window) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
        }
        for scope in [QuickSendScope.current, .tab, .all, .visible] {
            controller.chooseQuickSendScope(scope)
            checks["saved-\(scope.rawValue)"] = (try? controller.store.load().preferences.quickSendScope) == scope
            let restored = WorkspaceController(store: controller.store)
            checks["restored-\(scope.rawValue)"] = restored.quickSendScope == scope
            restored.shutdown(); restored.window?.close()
        }
        controller.chooseQuickSendScope(.all)
        let revision = controller.configurationRevision
        modal { _ = PopupKeyboard.dismiss(window: $0) }
        controller.chooseQuickSendScope(.selected)
        checks["cancelKeepsPreviousScope"] = controller.quickSendScope == .all && controller.configurationRevision == revision
        controller.toggleQuickSendBar(); controller.toggleQuickSendBar()
        checks["hideShowKeepsScope"] = controller.quickSendScope == .all && controller.configuration.preferences.quickSendScope == .all
        controller.newLocal()
        modal { window in
            let buttons = descendants(window.contentView!).compactMap { $0 as? NSButton }
            buttons.first { $0.title.hasPrefix("1. ") }?.state = .on
            buttons.first { $0.title == "确定" }?.performClick(nil)
        }
        controller.chooseQuickSendScope(.selected)
        checks["manualScopeSaved"] = controller.configuration.preferences.quickSendScope == .selected && controller.quickSendSelected.count == 1
        let restored = WorkspaceController(store: controller.store)
        restored.newLocal()
        checks["manualModeRestoredWithoutStaleTargets"] = restored.quickSendScope == .selected && restored.quickSendSelected.isEmpty && restored.quickSendTargets.isEmpty
        checks["sendDisabledUntilTargetsSelected"] = descendants(restored.quickSendBar).compactMap { $0 as? NSButton }.first { $0.title == "发送" }?.isEnabled == false
        checks["selectionCheckmarkRestored"] = descendants(restored.quickSendBar).compactMap { $0 as? NSPopUpButton }.flatMap { $0.menu?.items ?? [] }.contains { $0.title == QuickSendScope.selected.title && $0.state == .on }
        restored.shutdown(); restored.window?.close()
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_QUICKSEND_PERSISTENCE_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print(report); controller.shutdown(); NSApp.terminate(nil)
    }
}
