// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum DirectoryPickerStressTest {
    private final class WindowReference {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        let directories = (0..<100).flatMap { group in (0..<12).map { "Group\(group)/Child\($0)" } }
        let editor = SessionEditor(SessionProfile(name: "Directory fixture", group: "Group0/Child0", host: "example.test"), profiles: [], directories: directories, initialDirectory: "")
        var previous: String?, cycles = 0
        var children = [WindowReference]()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func later(_ body: @escaping () -> Void) {
            let timer = Timer(timeInterval: 0.03, repeats: false) { _ in body() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func close(_ title: String) {
            guard let root = NSApp.modalWindow?.contentView else { checks["modalAvailable"] = false; NSApp.abortModal(); return }
            views(root).compactMap { $0 as? NSButton }.first { $0.title == title }?.performClick(nil)
        }
        func scrollTree(_ tree: SessionDirectoryTree, _ index: Int) {
            let outline = tree.outline
            if let window = NSApp.modalWindow {
                children.append(WindowReference(window))
                checks["cycle\(index)ManualFocusLoop"] = !window.autorecalculatesKeyViewLoop
            }
            outline.expandItem(nil, expandChildren: true)
            for row in stride(from: 0, to: outline.numberOfRows, by: 79) {
                outline.scrollRowToVisible(row); outline.layoutSubtreeIfNeeded(); outline.displayIfNeeded()
            }
            for row in stride(from: outline.numberOfRows - 1, through: 0, by: -83) {
                outline.scrollRowToVisible(row); outline.layoutSubtreeIfNeeded()
            }
            for delta: Int32 in [-80, -80, 60, 100, -120, 160] {
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: cg) {
                    outline.enclosingScrollView?.scrollWheel(with: event)
                }
            }
            checks["cycle\(index)Rows"] = outline.numberOfRows > 1000
            checks["cycle\(index)Select"] = tree.selectDirectory("Group\(index)/Child4")
            NSApp.modalWindow?.makeFirstResponder(outline)
            if index % 3 == 0 {
                // macOS may exclude buttons from Tab navigation when Full
                // Keyboard Access is off; honor that preference in the test.
                let buttons = NSApp.modalWindow?.contentView.map { root in views(root).compactMap { $0 as? NSButton } } ?? []
                let controls: [NSView] = [outline] + ["选择", "取消"].compactMap { title in buttons.first { $0.title == title && $0.canBecomeKeyView } }
                NSApp.modalWindow?.selectNextKeyView(nil)
                checks["cycle\(index)KeyboardSelect"] = NSApp.modalWindow?.firstResponder === controls[1 % controls.count]
                NSApp.modalWindow?.selectNextKeyView(nil)
                checks["cycle\(index)KeyboardCancel"] = NSApp.modalWindow?.firstResponder === controls[2 % controls.count]
                NSApp.modalWindow?.selectNextKeyView(nil)
                checks["cycle\(index)KeyboardReturnsToTree"] = NSApp.modalWindow?.firstResponder === controls[3 % controls.count]
            }
            later {
                if index % 4 == 3, let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
                else { close(index % 2 == 0 ? "选择" : "取消") }
            }
        }
        func cycle() {
            guard cycles < 30 else { close("取消"); return }
            let index = cycles; cycles += 1
            guard let root = NSApp.modalWindow?.contentView,
                  let picker = views(root).compactMap({ $0 as? SessionDirectoryPicker }).first else {
                checks["parentPickerAvailable"] = false; NSApp.abortModal(); return
            }
            previous = picker.selectedDirectory
            later {
                guard let root = NSApp.modalWindow?.contentView, let tree = views(root).compactMap({ $0 as? SessionDirectoryTree }).first else {
                    checks["cycle\(index)Tree"] = false; NSApp.abortModal(); return
                }
                scrollTree(tree, index)
            }
            autoreleasepool { picker.performClick(nil) }
            checks["cycle\(index)Result"] = picker.selectedDirectory == (index % 2 == 0 ? "Group\(index)/Child4" : previous)
            checks["cycle\(index)ParentAlive"] = NSApp.modalWindow === editor.dialog.window
            later {
                checks["cycle\(index)WindowsReleased"] = children.filter { $0.window != nil }.count <= 1
                cycle()
            }
        }
        later { cycle() }
        let result = editor.run()
        checks["allCyclesCompleted"] = cycles == 30
        checks["parentCancelPreserved"] = result == nil
        if let path = ProcessInfo.processInfo.environment["OSHELL_DIRECTORY_STRESS_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
