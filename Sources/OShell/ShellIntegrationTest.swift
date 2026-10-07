// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum ShellIntegrationTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool](), prefs = Preferences(); prefs.metal = false
        var profile = SessionProfile(name: "集成", host: "192.0.2.1")
        profile.activeHostProbe = false
        let pane = TerminalPane(profile: profile, preferences: prefs, knownHostsFile: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
        checks["explicitModeNeverAllowsProbe"] = !pane.allowsActiveHostProbe
        var legacyProfile = SessionProfile(name: "主动", host: "192.0.2.2"); legacyProfile.activeHostProbe = true
        let automatic = TerminalPane(profile: legacyProfile, preferences: prefs, knownHostsFile: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
        checks["explicitOptInAllowsLegacyProbe"] = automatic.allowsActiveHostProbe
        func frame(_ payload: String) -> String { "\u{1b}]777;OShellHost=1;" + payload + "\u{7}" }
        for byte in frame("outer-real|10.20.0.1|").utf8 { pane.terminal.feed(byteArray: [byte][...]) }
        checks["fragmentedMetadataRecognized"] = pane.title == "outer-real · 10.20.0.1" && pane.hasShellIntegration
        checks["metadataDoesNotAppearAsTerminalText"] = !String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("OShellHost")
        automatic.terminal.feed(text: frame("auto|10.30.0.1|"))
        checks["reportAutomaticallyStopsFutureProbes"] = automatic.hasShellIntegration && !automatic.allowsActiveHostProbe
        pane.setTerminalTitle(source: pane.terminal, title: "root@custom-prompt:~")
        checks["integrationWinsOverPromptAlias"] = pane.title == "outer-real · 10.20.0.1"
        pane.noteUserInput(Array("ssh inner\r".utf8)[...])
        checks["nestedWithoutScriptDoesNotKeepOuterIP"] = pane.remoteAddress == nil && !pane.allowsActiveHostProbe
        pane.terminal.feed(text: frame("inner-real|10.40.0.1|"))
        checks["nestedReportChangesIdentity"] = pane.title == "inner-real · 10.40.0.1"
        pane.noteUserInput(Array("exit\r".utf8)[...]); pane.terminal.feed(text: frame("outer-real|10.20.0.1|"))
        checks["returnReportRestoresOuter"] = pane.title == "outer-real · 10.20.0.1"
        pane.terminal.feed(text: frame("bad host|10.50.0.1|"))
        checks["invalidMetadataIgnored"] = pane.title == "outer-real · 10.20.0.1"
        pane.terminal.feed(text: "\u{1b}[?1049h" + frame("editor-fake|10.50.0.1|") + "\u{1b}[?1049l")
        checks["alternateScreenMetadataIgnored"] = pane.title == "outer-real · 10.20.0.1"
        pane.terminal.feed(text: "\u{1b}c" + frame("after-reset|10.60.0.1|"))
        checks["terminalResetPreservesReceiver"] = pane.title == "after-reset · 10.60.0.1"
        pane.receive(Data((frame("integrated-real|10.70.0.1|") + "\r\n[root@alias ~]# ").utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            checks["reportedNameSurvivesPromptAlias"] = pane.title == "integrated-real · 10.70.0.1"
            // A host switch performed by an alias may not be visible as 'ssh' input.
            pane.receive(Data("\r\n[root@plain-inner ~]# ".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                checks["missingIntegrationFallsBackToDifferentPrompt"] = pane.title == "plain-inner · IP 待识别" && !pane.allowsActiveHostProbe
                pane.terminal.feed(text: "\u{1b}]0;ops@osc-inner:/srv\u{7}")
                checks["passiveOSCTitleStillUpdates"] = pane.title == "osc-inner · IP 待识别"
                pane.terminal.feed(text: "\u{1b}]7;file://directory-host/srv\u{7}")
                checks["passiveOSC7StillUpdates"] = pane.title == "directory-host · IP 待识别"
                let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
                if let path = ProcessInfo.processInfo.environment["OSHELL_SHELL_INTEGRATION_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
                print(report); pane.shutdown(); automatic.shutdown(); controller.shutdown(); NSApp.terminate(nil)
            }
        }
    }
}
