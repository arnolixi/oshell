// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Foundation

enum SmokeTest {
    static func run(_ controller: WorkspaceController) {
        controller.newLocal()
        controller.splitVertical(); controller.splitHorizontal()
        controller.newLocal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            controller.selectedTab?.activePane.terminal.process.send(data: Array("printf 'OSHELL_SMOKE_OK\\n'\r".utf8)[...])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var durations = [Double]()
            for _ in 0..<100 {
                let start = DispatchTime.now().uptimeNanoseconds
                controller.nextTab()
                durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let marker = String(decoding: controller.selectedTab?.activePane.terminal.getTerminal().getBufferAsData() ?? Data(), as: UTF8.self)
            var result = controller.diagnosticSnapshot
            result["markerReceived"] = marker.contains("OSHELL_SMOKE_OK")
            result["switchMeanMs"] = durations.reduce(0, +) / Double(durations.count)
            result["switchP95Ms"] = durations.sorted()[94]
            result["switchMaxMs"] = durations.max()
            if let destination = ProcessInfo.processInfo.environment["OSHELL_SMOKE_OUTPUT"],
               let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: destination))
            }
            print(String(data: (try? JSONSerialization.data(withJSONObject: result)) ?? Data(), encoding: .utf8) ?? "")
        }
        if !CommandLine.arguments.contains("--keep-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { controller.shutdown(); NSApp.terminate(nil) }
        }
    }
}
