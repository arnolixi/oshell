// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum TabBehaviorTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool]()
        var preferences = controller.configuration.preferences; preferences.metal = false
        let profile = SessionProfile(name: "自动名称", host: "gateway.test", username: "root")
        let pane = TerminalPane(profile: profile, preferences: preferences)
        var fixedProfile = profile; fixedProfile.name = "保存名称"
        let fixed = TerminalPane(profile: fixedProfile, preferences: preferences)
        let pinned = TerminalPane(profile: profile, preferences: preferences, terminalType: "xterm")
        func feed(_ target: TerminalPane, _ value: String) { target.receive(Data(value.utf8)) }
        func later(_ action: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: action) }
        func finish() {
            [pane, fixed, pinned].forEach { $0.shutdown() }
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            if let path = ProcessInfo.processInfo.environment["OSHELL_TAB_BEHAVIOR_OUTPUT"] {
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            }
            controller.shutdown(); NSApp.terminate(nil)
        }
        func keyboard() {
            for _ in 0..<13 { controller.newLocal() }
            let tabs = controller.tabs, window = controller.window!
            var forwarded = 0
            for tab in tabs {
                let original = tab.activePane.onUserInput
                tab.activePane.onUserInput = { pane, bytes in forwarded += 1; return original?(pane, bytes) ?? false }
            }
            func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                print("Tab keyboard diagnostic: code=\(code) keyWindow=\(window.isKeyWindow) active=\(NSApp.isActive) modal=\(NSApp.modalWindow != nil)")
                NSApp.sendEvent(event)
            }
            key(48, .control, "\t"); checks["nextWrapsFromLastToFirst"] = controller.selectedTab === tabs.first
            key(48, [.control, .shift], "\u{19}"); checks["previousWrapsFromFirstToLast"] = controller.selectedTab === tabs.last
            controller.select(tabs[3]); controller.select(tabs[9])
            key(50, .control, "`"); checks["recentSwitchesBack"] = controller.selectedTab === tabs[3]
            key(50, .control, "`"); checks["recentSwitchesForwardAgain"] = controller.selectedTab === tabs[9]
            controller.select(tabs[9]); controller.arrange(.tiled)
            key(50, .control, "`"); checks["focusAndLayoutDoNotPolluteHistory"] = controller.selectedTab === tabs[3]
            controller.arrange(.tabs)
            key(30, [.command, .shift], "}"); checks["legacyNextShortcut"] = controller.selectedTab === tabs[4]
            key(33, [.command, .shift], "{"); checks["legacyPreviousShortcut"] = controller.selectedTab === tabs[3]
            checks["navigationNeverSentToPTY"] = forwarded == 0
            controller.newLocal(); let created = controller.selectedTab!
            controller.lastUsedTab(); checks["newTabRecordsPrevious"] = controller.selectedTab === tabs[3]
            controller.lastUsedTab(); checks["canReturnToNewTab"] = controller.selectedTab === created
            controller.duplicateTab(created); let duplicate = controller.selectedTab!
            controller.lastUsedTab(); checks["duplicateRecordsPrevious"] = controller.selectedTab === created
            controller.lastUsedTab(); duplicate.layout.panes.forEach { $0.shutdown() }; controller.closeTab()
            controller.lastUsedTab(); checks["closedTabsRemovedFromHistory"] = controller.selectedTab !== duplicate && controller.tabs.contains { $0 === controller.selectedTab }
            func menuItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) } }
            let items = menuItems(NSApp.mainMenu!)
            checks["shortcutsVisibleInMenu"] = items.contains { $0.action == #selector(WorkspaceController.nextTab) && $0.keyEquivalent == "\t" && $0.keyEquivalentModifierMask == .control }
                && items.contains { $0.action == #selector(WorkspaceController.lastUsedTab) && $0.keyEquivalent == "`" && $0.keyEquivalentModifierMask == .control }
            controller.tabs.flatMap { $0.layout.panes }.forEach { $0.shutdown() }
            while !controller.tabs.isEmpty { controller.closeTab() }
            controller.nextTab(); controller.previousTab(); controller.lastUsedTab()
            checks["emptyHistoryIsSafe"] = controller.selectedTab == nil
            controller.newLocal(); controller.lastUsedTab(); checks["singleTabHistoryIsSafe"] = controller.tabs.count == 1 && controller.selectedTab === controller.tabs.first
            finish()
        }
        feed(pane, "\u{1b}]2;root@gateway.test:~\u{7}")
        checks["outerOSC"] = (pane.title == "gateway.test" && pane.remoteAddress == nil)
        for byte in "\u{1b}]0;admin@app-node:/srv\u{1b}\\".utf8 { pane.receive(Data([byte])) }
        checks["fragmentedNestedOSC"] = (pane.title == "app-node" && pane.remoteAddress == nil)
        feed(pane, "\u{1b}]7;file://db-node/var/lib\u{7}")
        checks["nestedDirectoryUpdatesHost"] = (pane.title == "db-node" && pane.remoteAddress == nil)
        checks["nestedDirectoryDoesNotRetargetSFTP"] = pane.remoteDirectory == "." && pane.profile.host == "gateway.test"
        feed(pane, "\u{1b}]2;root@gateway.test:~\u{7}")
        checks["returnToOuterOSC"] = (pane.title == "gateway.test" && pane.remoteAddress == nil)
        feed(pane, "\u{1b}]2;vim /etc/hosts\u{7}")
        checks["applicationTitleNotMistakenForHost"] = (pane.title == "gateway.test" && pane.remoteAddress == nil)
        for target in [fixed, pinned] { feed(target, "\u{1b}]2;root@unwanted:~\u{7}\u{1b}]7;file://unwanted/tmp\u{7}\r\n[root@unwanted ~]# ") }
        feed(pane, "\r\n\u{1b}[32m[root@centos6 ~]# \u{1b}[0m")
        later {
            checks["centosPromptFallback"] = (pane.title == "centos6" && pane.remoteAddress == nil)
            checks["savedNameDoesNotOverrideTitle"] = (fixed.title == "unwanted" && fixed.remoteAddress == nil)
            checks["externalSessionUsesDetectedHost"] = (pinned.title == "unwanted" && pinned.remoteAddress == nil)
            feed(pane, "\r\u{1b}[Kroot@ubuntu:/srv$ ")
            later {
                checks["nestedPromptFallback"] = (pane.title == "ubuntu" && pane.remoteAddress == nil)
                feed(pane, "ssh root@wrong-host\r\nPassword: ")
                later {
                    checks["typedSSHAndPasswordPromptIgnored"] = (pane.title == "ubuntu" && pane.remoteAddress == nil)
                    feed(pane, "\u{1b}[?1049h\r\n[root@fake-editor ~]# ")
                    later {
                        checks["alternateScreenPromptIgnored"] = (pane.title == "ubuntu" && pane.remoteAddress == nil)
                        feed(pane, "\u{1b}[?1049l\r\n[root@centos6 ~]# ")
                        later {
                            checks["returnToOuterPrompt"] = (pane.title == "centos6" && pane.remoteAddress == nil)
                            feed(pane, String(repeating: "\r\nordinary output", count: 60) + "\r\n[root@deep-node ~]# ")
                            pane.terminal.getTerminal().buffer.yDisp = 0
                            later {
                                checks["scrolledViewportDoesNotChangeHostDetection"] = (pane.title == "deep-node" && pane.remoteAddress == nil)
                                pane.shutdown(); feed(pane, "\u{1b}]2;root@closed:~\u{7}")
                                checks["closedPaneCannotChangeTitle"] = (pane.title == "deep-node" && pane.remoteAddress == nil)
                                keyboard()
                            }
                        }
                    }
                }
            }
        }
    }
}
