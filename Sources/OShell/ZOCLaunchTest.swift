// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Activated only by the isolated launcher fixture, including a real cold start.
enum ZOCLaunchTest {
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_ZOC_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        do {
            try controller.store.save(controller.configuration)
            let before = try Data(contentsOf: controller.store.url)
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
            let endpoint = try LaunchEndpoint.directory(for: controller.store.url.deletingLastPathComponent())
            try Data(endpoint.path.utf8).write(to: root.appendingPathComponent("endpoint.txt"))
            try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: root.appendingPathComponent("app.pid"))
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: String]
            var finished = false
            func finish(_ success: Bool) {
                guard !finished else { return }; finished = true
                let panes = controller.inputPanes
                let checks: [String: Bool] = [
                    "threeLaunchesOneWorkspace": success && controller.tabs.count == 3,
                    "oneTimePasswordsAuthenticated": panes.count == 3 && panes.allSatisfy { $0.sessionReady && $0.remoteAddress != nil && String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("USM_MOCK_READY") },
                    "callerTitlesIgnored": panes.allSatisfy { $0.title == "asset-real · 10.20.0.9" },
                    "unifiedIdentityTitle": panes.allSatisfy { $0.title.contains(" · ") && $0.remoteAddress != nil },
                    "noPersistentCredentials": panes.allSatisfy { $0.profile.encryptedPassword == nil } && (try? Data(contentsOf: controller.store.url)) == before,
                    "passwordNotInTerminal": panes.allSatisfy { !String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains(fixture["password"]!) }
                ]
                let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("app-result.json"))
                controller.shutdown(); NSApp.terminate(nil)
            }
            let deadline = Date().addingTimeInterval(35)
            func poll() {
                if controller.tabs.count == 3 && controller.inputPanes.allSatisfy({ $0.sessionReady && $0.remoteAddress != nil && String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("USM_MOCK_READY") }) { finish(true) }
                else if Date() > deadline { finish(false) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() } }
            }
            DispatchQueue.main.async { poll() }
        } catch {
            try? Data("setup failed".utf8).write(to: root.appendingPathComponent("setup-error.txt"))
            controller.shutdown(); NSApp.terminate(nil)
        }
    }
}
