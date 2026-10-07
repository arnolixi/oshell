// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum HostIdentityTest {
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_IDENTITY_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        var checks = [String: Bool](), finished = false
        func finish() {
            guard !finished else { return }; finished = true
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "titles": controller.inputPanes.map(\.title),
                "terminalTail": controller.inputPanes.map { String(String(decoding: $0.terminal.getTerminal().getBufferAsData(), as: UTF8.self).suffix(1600)) }]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
            controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(15)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; next() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll) }
            }; poll()
        }
        func verifyLocalPaths(command: String, password: String) {
            controller.newLocal(); let local = controller.selectedTab!.activePane
            let host = LocalHostIdentity.current()
            checks["localUsesSameTitleFormat"] = local.title == host.hostname + " · " + (host.address ?? "IP 待识别")
            func text() -> String { String(decoding: local.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
            func passwords() -> Int { text().components(separatedBy: "password:").count }
            let before = passwords()
            local.sendManaged(Array(command.utf8))
            wait("localShellSSHPasswordPrompt", { passwords() > before }) {
                local.sendManaged(Array((password + "\r").utf8))
                wait("localShellTracksSSHHost", { local.title == "inner-real · 10.30.0.8" }) {
                    local.sendManaged(Array("exit\r".utf8))
                    wait("localShellReturnRestoresHost", { local.title.hasPrefix(host.hostname + " · ") && local.remoteAddress != "10.30.0.8" }) {
                        local.sendManaged(Array("exit\r".utf8))
                        wait("endedShellUsesLocalIdentity", { local.ended && local.title == host.hostname + " · " + (host.address ?? "IP 待识别") }) {
                            checks["idleLocalIdentityCanRefresh"] = local.canRefreshHostIdentity
                            local.refreshHostIdentity()
                            let count = passwords()
                            local.handleEndedInput(Array(command.utf8)[...])
                            wait("localToolSSHPasswordPrompt", { local.isRunningLocalTool && passwords() > count }) {
                                local.handleEndedInput(Array((password + "\r").utf8)[...])
                                wait("localToolTracksSSHHost", { local.title == "inner-real · 10.30.0.8" }) {
                                    checks["noToolNameSuffix"] = !local.title.contains("本机") && !local.title.contains("ssh")
                                    local.handleEndedInput(Array("exit\r".utf8)[...])
                                    wait("localToolReturnRestoresHost", { !local.isRunningLocalTool && local.title == host.hostname + " · " + (host.address ?? "IP 待识别") }) { finish() }
                                }
                            }
                        }
                    }
                }
            }
        }
        do {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
            try controller.store.save(controller.configuration)
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
            let request = try ZOCLaunchRequest.parse(["/DEV:SSH", "/CONNECT:test:\(fixture["password"] as! String)@127.0.0.1:\(fixture["outerPort"] as! Int)", "/TITLE:必须忽略的堡垒机标题", "/EMU:Xterm"])
            controller.openExternal(request)
            let pane = controller.selectedTab!.activePane
            func text() -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
            func send(_ value: String) { pane.sendManaged(Array(value.utf8)) }
            if fixture["integration"] as? Bool == false {
                wait("plainSSHUsesPromptOnly", { pane.title == "asset · IP 待识别" }) {
                    checks["plainSSHNeverAllowsProbe"] = !pane.allowsActiveHostProbe
                    send("printf '\\033]2;root@osc-host:~\\007'; sleep 1\r")
                    wait("plainSSHAcceptsOSCTitle", { pane.title == "osc-host · IP 待识别" }) {
                        wait("promptRestoresActualHint", { pane.title == "asset · IP 待识别" }) {
                            let nested = "ssh -F /dev/null -o UserKnownHostsFile=" + ConnectionValidation.quote(root.appendingPathComponent("known_hosts").path) + " -o StrictHostKeyChecking=yes -o PubkeyAuthentication=no -p \(fixture["innerPort"] as! Int) test@127.0.0.1\r"
                            send(nested)
                            wait("plainNestedPasswordPrompt", { text().contains("password:") }) {
                                checks["passiveRefreshDisabledAtPassword"] = !pane.canRefreshHostIdentity
                                send((fixture["password"] as! String) + "\r")
                                wait("plainNestedPromptIdentified", { pane.title == "asset · IP 待识别" }) {
                                    checks["plainNestedIPNotGuessed"] = pane.remoteAddress == nil
                                    pane.refreshHostIdentity()
                                    send("echo PASSIVE_INPUT_OK\r")
                                    wait("normalInputUnaffected", { text().contains("\nPASSIVE_INPUT_OK\n") }) {
                                        send("exit\r")
                                        wait("plainReturnPromptIdentified", { text().contains("Connection to 127.0.0.1 closed") && pane.title == "asset · IP 待识别" }) {
                                            checks["noHostnameCommandExecuted"] = !FileManager.default.fileExists(atPath: root.appendingPathComponent("probes.log").path)
                                            finish()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                return
            }
            wait("realShellReportsOuterIdentity", { pane.title == "outer-real · 10.20.0.10" && pane.terminal.getTerminal().getCursorLineText().contains("[root@asset ~]#") }) {
                checks["ignoresCallerAndGatewayAddress"] = !pane.title.contains("必须忽略") && !pane.title.contains("127.0.0.1")
                checks["queryEchoNotShown"] = !text().contains("OSHELL_INFO_")
                checks["initialProbeDoesNotAddPromptLine"] = text().components(separatedBy: "[root@asset ~]#").count == 2
                let nested = "ssh -F /dev/null -o UserKnownHostsFile=" + ConnectionValidation.quote(root.appendingPathComponent("known_hosts").path) + " -o StrictHostKeyChecking=yes -o PubkeyAuthentication=no -p \(fixture["innerPort"] as! Int) test@127.0.0.1\r"
                send(nested)
                wait("nestedPasswordPrompt", { text().contains("password:") }) {
                    checks["manualRefreshDisabledAtPasswordPrompt"] = !pane.canRefreshHostIdentity
                    pane.refreshHostIdentity()
                    // The probe must not send a command into a nested password prompt.
                    let before = (try? String(contentsOf: root.appendingPathComponent("probes.log"), encoding: .utf8)) ?? ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        checks["noProbeAtPasswordPrompt"] = before == ((try? String(contentsOf: root.appendingPathComponent("probes.log"), encoding: .utf8)) ?? "")
                        send((fixture["password"] as! String) + "\r")
                        wait("nestedSSHReportsInnerIdentity", { pane.title == "inner-real · 10.30.0.8" }) {
                            checks["probeRunsInCurrentShellNotGateway"] = pane.profile.host == "127.0.0.1" && pane.remoteAddress == "10.30.0.8"
                            send("exit\r")
                            wait("exitRestoresOuterIdentity", { pane.title == "outer-real · 10.20.0.10" }) {
                                // Both shells deliberately use the same user@asset prompt.
                                checks["samePromptHostnameDoesNotKeepInnerIP"] = true
                                send("unset SSH_CONNECTION\r")
                                wait("shellReadyForFallback", { text().contains("unset SSH_CONNECTION") }) {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        let promptCount = text().components(separatedBy: "[root@asset ~]#").count
                                        pane.refreshHostIdentity()
                                        wait("interfaceFallbackWithoutSSHConnection", { pane.title == "outer-real · 10.20.0.11" && pane.terminal.getTerminal().getCursorLineText().contains("[root@asset ~]#") }) {
                                            checks["manualProbeDoesNotAddPromptLine"] = text().components(separatedBy: "[root@asset ~]#").count == promptCount
                                            controller.duplicateTab(controller.selectedTab!)
                                            let clone = controller.selectedTab!.activePane
                                            wait("cloneProbesItsOwnShell", { clone.title == "outer-real · 10.20.0.10" && clone.terminal.getTerminal().getCursorLineText().contains("[root@asset ~]#") }) {
                                                checks["cloneProbeDoesNotAddPromptLine"] = String(decoding: clone.terminal.getTerminal().getBufferAsData(), as: UTF8.self).components(separatedBy: "[root@asset ~]#").count == 2
                                                checks["cloneDoesNotReusePreviousShellIP"] = pane.remoteAddress == "10.20.0.11" && clone.remoteAddress == "10.20.0.10"
                                                checks["noCallerTitleInClones"] = !clone.title.contains("必须忽略")
                                                func probes() -> String { (try? String(contentsOf: root.appendingPathComponent("probes.log"), encoding: .utf8)) ?? "" }
                                                let before = probes()
                                                clone.receive(Data("\u{1b}[?1049h\r\n[root@fake-editor ~]# ".utf8))
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                                    checks["noProbeInAlternateScreen"] = probes() == before && clone.title == "outer-real · 10.20.0.10"
                                                    clone.receive(Data("\u{1b}[?1049l".utf8))
                                                    clone.sendManaged(Array("printf '\\033]2;root@temporary:~\\007'\r".utf8))
                                                    clone.sendManaged(Array("echo USER_INPUT_STAYS".utf8))
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                                        checks["noProbeWhileEditingCommand"] = probes() == before
                                                        clone.sendManaged([13])
                                                        wait("typingAndProbeRemainOrdered", {
                                                            clone.title == "outer-real · 10.20.0.10" && String(decoding: clone.terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("\nUSER_INPUT_STAYS\n")
                                                        }) { verifyLocalPaths(command: nested, password: fixture["password"] as! String) }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch { checks["setup"] = false; finish() }
    }
}
