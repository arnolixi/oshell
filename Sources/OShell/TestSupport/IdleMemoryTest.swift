// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import SwiftTerm

/// Closing then immediately reopening must cancel idle cleanup; caches rebuild.
enum IdleMemoryTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool](), diagnostics = [String: String]()
        // Exercise every line-storage allocation path with an independent model.
        func cell(_ scalar: Int32) -> CharData {
            var value = CharData.Null; value.setValue(code: scalar, size: 1); return value
        }
        var storageOK = true
        for _ in 0..<100 {
            let row = BufferLine(cols: 0)
            var expected = [CharData]()
            for width in [2, 80, 240, 37, 1000, 0, 133] {
                let fill = cell(0x4e2d)
                row.resize(cols: width, fillData: fill)
                expected = Array(expected.prefix(width)) + Array(repeating: fill, count: max(0, width - expected.count))
                for index in 0..<width where index % 3 == 0 { row[index] = cell(65 + Int32(index % 26)); expected[index] = row[index] }
                storageOK = storageOK && row.getData().map { $0.getCharacter() } == expected.map { $0.getCharacter() }
                let copy = BufferLine(from: row), destination = BufferLine(cols: width + 20)
                destination.copyFrom(line: copy)
                let grown = BufferLine(cols: 0); grown.copyFrom(line: row)
                if width > 0 { row[0] = cell(90) }
                for snapshot in [copy, destination, grown] {
                    storageOK = storageOK && snapshot.getData().map { $0.getCharacter() } == expected.map { $0.getCharacter() }
                }
                if width > 0 { expected[0] = cell(90) }
            }
        }
        checks["lineStorageResizeCopyAndZeroWidth"] = storageOK
        func text(_ pane: TerminalPane) -> String {
            // Use the same grapheme resolution as terminal selection/copy.
            let terminal = pane.terminal.getTerminal()
            return terminal.getText(start: Position(col: 0, row: 0), end: Position(col: terminal.cols, row: terminal.rows - 1))
        }
        func later(_ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: block) }
        func closeCurrent() { controller.selectedTab?.activePane.shutdown(); controller.closeTab() }
        func feedMarker() {
            controller.selectedTab?.activePane.receive(Data("\r\n\u{1b}[31m内存回归 中文 😀\u{1b}[0m\r\nREOPEN_RENDER_OK\r\n".utf8))
        }
        controller.newLocal(); closeCurrent(); controller.newLocal(); feedMarker()
        later {
            checks["immediateReopenCancelsCleanup"] = controller.idleMemoryReclaimer.completedPasses == 0
            let pane = controller.selectedTab!.activePane
            checks["activeTerminalHistoryPreserved"] = text(pane).contains("内存回归 中文 😀")
            if checks["activeTerminalHistoryPreserved"] == false { diagnostics["activeText"] = text(pane) }
            checks["activeProcessPreserved"] = pane.terminal.process.running
            closeCurrent()
            later {
                checks["lastCloseReclaimsOnce"] = controller.idleMemoryReclaimer.completedPasses == 1
                controller.newLocal(); feedMarker()
                later {
                    let pane = controller.selectedTab!.activePane
                    checks["reopensAfterCacheRelease"] = pane.terminal.process.running && text(pane).contains("REOPEN_RENDER_OK")
                    checks["metalRestartsAfterCacheRelease"] = pane.terminal.isUsingMetalRenderer && pane.terminal.metalRendererStatus.presentedFrameCount > 0
                    // Ending a connection keeps its tab/history; it must not trigger idle cleanup.
                    pane.terminal.process.send(data: Array("exit\r".utf8)[...])
                    later {
                        checks["endedTabStillRetainsHistory"] = pane.ended && !pane.isShutdown && controller.tabs.count == 1 && text(pane).contains("内存回归 中文 😀")
                        if checks["endedTabStillRetainsHistory"] == false { diagnostics["endedText"] = text(pane) }
                        checks["endedTabDoesNotTriggerReclaim"] = controller.idleMemoryReclaimer.completedPasses == 1
                        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "diagnostics": diagnostics]
                        if let path = ProcessInfo.processInfo.environment["OSHELL_IDLE_MEMORY_OUTPUT"] {
                            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
                        }
                        controller.shutdown(); NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}
