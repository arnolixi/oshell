// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

enum LocalToolTest {
    static func run(_ controller: WorkspaceController) {
        guard let location = ProcessInfo.processInfo.environment["OSHELL_LOCAL_TOOL_ROOT"] else { return }
        let root = URL(fileURLWithPath: location)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("fixture.json")), let f = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var checks = [String: Bool](), finished = false
        var diagnostics = [String: String]()
        func text(_ pane: TerminalPane) -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func send(_ pane: TerminalPane, _ value: String) { pane.terminal.insertText(value, replacementRange: NSRange(location: 0, length: 0)) }
        func finish() {
            guard !finished else { return }; finished = true
            let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "diagnostics": diagnostics]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
            print(result); controller.shutdown(); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(18)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; action() }
                else if Date() > deadline {
                    checks[label] = false
                    diagnostics[label] = controller.inputPanes.map { "tool=\($0.localToolName ?? "none") pid=\($0.localToolPID)\n" + String(text($0).suffix(2000)).replacingOccurrences(of: f["password"] as! String, with: "[test-secret]") }.joined(separator: "\n---\n")
                    finish()
                }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() } }
            }; poll()
        }
        func diagnosticsTools(_ pane: TerminalPane, done: @escaping () -> Void) {
            send(pane, "tools\r")
            checks["toolsListsPathsWithoutStartingProcess"] = !pane.isRunningLocalTool && text(pane).contains("/usr/bin/dig") && text(pane).contains("networkQuality")
            let dns = f["dnsPort"] as! Int, http = f["httpPort"] as! Int
            let steps: [(String, String, String)] = [
                ("digLoopbackDNS", "dig @127.0.0.1 -p \(dns) dig.oshell.test A +short", "127.0.0.42"),
                ("nslookupLoopbackDNS", "nslookup -port=\(dns) lookup.oshell.test 127.0.0.1", "127.0.0.43"),
                ("hostVersion", "host -V", "host 9."),
                ("ncLoopbackPort", "nc -z -v -w 2 127.0.0.1 \(http)", "succeeded"),
                ("opensslVersion", "openssl version", "LibreSSL "),
                ("ifconfigLoopback", "ifconfig lo0", "LOOPBACK"),
                ("routeReadOnlyLookup", "route -n get 127.0.0.1", "interface: lo0"),
                ("netstatTCPStatistics", "netstat -s -p tcp", "tcp:"),
                ("tcpdumpVersionOnly", "tcpdump -h", "tcpdump version")
            ]
            func next(_ index: Int) {
                guard index < steps.count else { done(); return }
                let step = steps[index]; send(pane, step.1 + "\r")
                wait(step.0, { !pane.isRunningLocalTool && text(pane).contains(step.2) }) { next(index + 1) }
            }
            next(0)
        }
        if CommandLine.arguments.contains("--command-connection-test") {
            controller.newBlankTab(); let tab = controller.selectedTab!, pane = tab.activePane
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            func status() -> TabStripView.ConnectionStatus? {
                controller.window?.contentView.flatMap { root in views(root).compactMap { $0 as? TabStripView.Item }.first { $0.id == tab.id }?.connectionStatus }
            }
            let known = root.appendingPathComponent("known_hosts").path
            let ssh = "ssh -F /dev/null -oStrictHostKeyChecking=yes -oUserKnownHostsFile='\(known)' -oPubkeyAuthentication=no -oPreferredAuthentications=password -p \(f["sshPort"] as! Int) oshell-local-test@127.0.0.1\r"
            checks["blankStartsRed"] = status() == .disconnected
            send(pane, ssh)
            wait("commandSSHRequestsAuthentication", { text(pane).lowercased().contains("password:") }) {
                checks["authenticationShowsGreen"] = status() == .commandConnection && pane.tabConnectionStatus.color == .systemGreen
                checks["tooltipDescribesCommandConnection"] = pane.connectionDetails.contains("命令行连接") && pane.connectionDetails.contains("协议：SSH")
                send(pane, (f["password"] as! String) + "\r")
                wait("commandSSHAuthenticated", { text(pane).contains("LOCAL_SSH_READY") }) {
                    checks["authenticatedBlankTabStaysGreen"] = pane.isBlank && pane.ended && status() == .commandConnection
                    checks["commandPasswordNotEchoed"] = !text(pane).contains(f["password"] as! String)
                    send(pane, "hello\r")
                    wait("commandSSHUsable", { text(pane).contains("LOCAL_SSH_ECHO_OK") }) {
                        send(pane, "exit\r")
                        wait("commandSSHExitReturnsRed", { !pane.isRunningLocalTool && status() == .disconnected }) {
                            checks["sshExitKeepsBlankTab"] = controller.tabs.count == 1 && controller.selectedTab === tab
                            send(pane, ssh)
                            wait("secondCommandSSHWaiting", { pane.isRunningLocalTool && pane.terminal.getTerminal().getCursorLineText().lowercased().contains("password:") }) {
                                checks["secondConnectionGreen"] = status() == .commandConnection
                                send(pane, "\u{3}")
                                wait("cancelledCommandSSHReturnsRed", { !pane.isRunningLocalTool && status() == .disconnected }) {
                                    send(pane, "ssh -F /dev/null -oBatchMode=yes -oConnectTimeout=1 -p 1 127.0.0.1\r")
                                    wait("failedCommandSSHReturnsRed", { !pane.isRunningLocalTool && status() == .disconnected }) {
                                        send(pane, "ping 127.0.0.1\r")
                                        wait("diagnosticCommandRunning", { pane.isRunningLocalTool && text(pane).contains("icmp_seq=0") }) {
                                            checks["diagnosticCommandRemainsRed"] = status() == .disconnected
                                            send(pane, "\u{3}")
                                            wait("diagnosticCommandEnded", { !pane.isRunningLocalTool }) {
                                                send(pane, "telnet 127.0.0.1 \(f["telnetPort"] as! Int)\r")
                                                wait("commandTelnetConnected", { text(pane).contains("LOCAL_TELNET_READY") }) {
                                                    checks["telnetConnectionGreen"] = status() == .commandConnection
                                                    send(pane, "quit\r")
                                                    wait("commandTelnetExitReturnsRed", { !pane.isRunningLocalTool && status() == .disconnected }) { finish() }
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
            return
        }
        controller.newLocal(); let pane = controller.selectedTab!.activePane
        controller.newLocal(); let peer = controller.selectedTab!.activePane
        for p in [pane, peer] { p.terminal.process.send(data: Array("exit\r".utf8)[...]) }
        wait("originalProcessesEnded", { pane.ended && peer.ended }) {
            checks["toolsLazyUntilCommand"] = !pane.isRunningLocalTool && pane.localToolPID == 0
            controller.chooseQuickSendScope(.all)
            checks["quickSendLaunchesToolsOnAllTabs"] = controller.sendQuickCommand(.init(text: "ping -c 1 127.0.0.1", appendReturn: true))
            checks["toolTitleUsesHostAndIPOnly"] = pane.title == LocalHostIdentity.current().hostname && !pane.title.contains("ping")
            wait("pingCompletesAndReturnsPrompt", { [pane, peer].allSatisfy { !$0.isRunningLocalTool && text($0).contains("1 packets transmitted") } }) {
                let http = "http://127.0.0.1:\(f["httpPort"] as! Int)/"
                send(pane, "curl --silent '\(http)'\r")
                wait("curlOutputDrainedBeforePrompt", {
                    let output = text(pane)
                    guard !pane.isRunningLocalTool, let tail = output.range(of: "LOCAL_CURL_TAIL", options: .backwards), let prompt = output.range(of: "OShell >", options: .backwards) else { return false }
                    return tail.upperBound < prompt.lowerBound
                }) {
                    send(pane, "traceroute -n -m 1 -w 1 127.0.0.1\r")
                    wait("tracerouteReturns", { !pane.isRunningLocalTool && text(pane).contains("traceroute to 127.0.0.1") }) {
                        send(pane, "telnet 127.0.0.1 \(f["telnetPort"] as! Int)\r")
                        wait("telnetInteractiveConnected", { text(pane).contains("LOCAL_TELNET_READY") }) {
                            checks["interactiveToolExcludedFromBroadcast"] = !pane.acceptsManagedInput
                            send(pane, "hello\r")
                            wait("telnetInteractiveEcho", { text(pane).contains("LOCAL_TELNET_ECHO_OK") }) {
                                send(pane, "quit\r")
                                wait("telnetReturnsWithoutClosingTab", { !pane.isRunningLocalTool && controller.tabs.count == 2 }) {
                                    controller.syncTargets = [pane.id, peer.id]
                                    let known = root.appendingPathComponent("known_hosts").path
                                    send(pane, "ssh -oStrictHostKeyChecking=yes -oUserKnownHostsFile='\(known)' -oPubkeyAuthentication=no -oPreferredAuthentications=password -p \(f["sshPort"] as! Int) oshell-local-test@127.0.0.1\r")
                                    wait("sshPasswordPrompt", { pane.isRunningLocalTool && text(pane).lowercased().contains("password:") }) {
                                        checks["sshStopsSyncBeforeAuthentication"] = controller.syncTargets.isEmpty && !pane.acceptsManagedInput
                                        controller.configuration.preferences.confirmMultilinePaste = false
                                        controller.pasteText((f["password"] as! String) + "\r", from: pane)
                                        wait("sshInteractiveAuthenticated", { text(pane).contains("LOCAL_SSH_READY") }) {
                                            checks["passwordNotEchoedOrBroadcast"] = !text(pane).contains(f["password"] as! String) && !text(peer).contains(f["password"] as! String)
                                            send(pane, "hello\r")
                                            wait("sshInteractiveEcho", { text(pane).contains("LOCAL_SSH_ECHO_OK") }) {
                                                send(pane, "exit\r")
                                                wait("sshReturnsToLocalPrompt", { !pane.isRunningLocalTool && controller.tabs.count == 2 }) {
                                                    // The launch was synchronized, so peer may also have an SSH tool.
                                                    if peer.isRunningLocalTool { peer.shutdown() }
                                                    send(pane, "ping 127.0.0.1\r")
                                                    wait("continuousPingRunning", { pane.isRunningLocalTool && text(pane).contains("icmp_seq=0") }) {
                                                        send(pane, "\u{3}")
                                                        wait("controlCStopsTool", { !pane.isRunningLocalTool }) {
                                                            send(pane, "curl --version\r\ncurl --version\r")
                                                            wait("queuedCommandsComplete", { !pane.isRunningLocalTool && text(pane).components(separatedBy: "Protocols:").count >= 3 }) {
                                                                diagnosticsTools(pane) {
                                                                let before = controller.tabs.count
                                                                send(pane, "quit\r")
                                                                checks["quitAtLocalPromptClosesTab"] = controller.tabs.count == before - 1 && pane.isShutdown
                                                                controller.newLocal(); let closing = controller.selectedTab!.activePane
                                                                closing.terminal.process.send(data: Array("exit\r".utf8)[...])
                                                                wait("cleanupTargetEnded", { closing.ended }) {
                                                                    send(closing, "ping 127.0.0.1\r")
                                                                    wait("cleanupToolRunning", { closing.isRunningLocalTool && closing.localToolPID > 0 }) {
                                                                        let pid = closing.localToolPID
                                                                        let accept = Timer(timeInterval: 0.05, repeats: true) { timer in
                                                                            if NSApp.modalWindow != nil { timer.invalidate(); NSApp.stopModal(withCode: .alertFirstButtonReturn) }
                                                                        }
                                                                        RunLoop.main.add(accept, forMode: .modalPanel)
                                                                        controller.closeTab(); accept.invalidate()
                                                                        checks["closingTabStopsToolState"] = closing.isShutdown && !closing.isRunningLocalTool
                                                                        wait("closingTabReapsToolProcess", { kill(pid, 0) != 0 && errno == ESRCH }) { finish() }
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
                            }
                        }
                    }
                }
            }
        }
    }
}
