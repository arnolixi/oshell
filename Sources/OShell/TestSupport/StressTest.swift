// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

enum StressTest {
    private static var timer: DispatchSourceTimer?
    static func run(_ controller: WorkspaceController) {
        controller.newLocal(); controller.splitVertical(); controller.splitHorizontal()
        let busyTab = controller.selectedTab!
        controller.newLocal(); controller.newLocal(); controller.newLocal(); controller.select(busyTab)
        var tickGaps = [Double](), switchTimes = [Double]()
        var last = DispatchTime.now().uptimeNanoseconds
        var ticks = 0
        let source = DispatchSource.makeTimerSource(queue: .main); timer = source
        source.schedule(deadline: .now() + 0.016, repeating: 0.016, leeway: .milliseconds(1))
        source.setEventHandler {
            let now = DispatchTime.now().uptimeNanoseconds
            tickGaps.append(Double(now - last) / 1_000_000); last = now; ticks += 1
            if ticks % 8 == 0 {
                let before = DispatchTime.now().uptimeNanoseconds
                controller.nextTab()
                switchTimes.append(Double(DispatchTime.now().uptimeNanoseconds - before) / 1_000_000)
            }
        }
        source.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            busyTab.layout.panes.forEach { pane in
                pane.terminal.process.send(data: Array("/usr/bin/awk 'BEGIN {for(i=0;i<400000;i++) print \"OSHELL_STRESS_\" i}'\r".utf8)[...])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13) {
            source.cancel(); timer = nil
            func p95(_ values: [Double]) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count) * 0.95))] }
            let result: [String: Any] = ["snapshot": controller.diagnosticSnapshot,
                "mainQueueTickGapP95Ms": p95(tickGaps), "mainQueueTickGapMaxMs": tickGaps.max() ?? 0,
                "tabSwitchP95Ms": p95(switchTimes), "tabSwitchMaxMs": switchTimes.max() ?? 0,
                "samples": tickGaps.count]
            if let destination = ProcessInfo.processInfo.environment["OSHELL_STRESS_OUTPUT"],
               let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: destination))
            }
            print(result); controller.shutdown(); NSApp.terminate(nil)
        }
    }
}
