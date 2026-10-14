// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum SFTPReuseTest {
    static func run(_ workspace: WorkspaceController) {
        guard let location = ProcessInfo.processInfo.environment["OSHELL_SFTP_REUSE_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: location)
        var checks = [String: Bool](), finished = false, files: RemoteFileWindow?
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let monitor = Timer(timeInterval: 0.03, repeats: true) { _ in
            guard let window = NSApp.modalWindow, let content = window.contentView else { return }
            if descendants(content).contains(where: { $0 is NSSecureTextField }) { checks["noSecondCredentialPrompt"] = false; _ = PopupKeyboard.dismiss(window: window) }
            else { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
        }
        RunLoop.main.add(monitor, forMode: .common); RunLoop.main.add(monitor, forMode: .modalPanel)
        checks["noSecondCredentialPrompt"] = true
        func finish() {
            guard !finished else { return }; finished = true
            files?.sessions.forEach { $0.shutdown() }; files?.close(); workspace.shutdown(); monitor.invalidate()
            try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("app-result.json"))
            NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ then: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(15)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; then() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
            }; poll()
        }
        do {
            try workspace.store.save(workspace.configuration); let before = try Data(contentsOf: workspace.store.url)
            let known = workspace.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts")
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: known)
            try Data((try LaunchEndpoint.directory(for: workspace.store.url.deletingLastPathComponent())).path.utf8).write(to: root.appendingPathComponent("endpoint.txt"))
            try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: root.appendingPathComponent("app.pid"))
            wait("sshAuthenticated", { workspace.selectedTab?.activePane.sessionReady == true && workspace.selectedTab?.activePane.sshConnectionGroup?.isAvailable == true }) {
                let terminal = workspace.selectedTab!.activePane, group = terminal.sshConnectionGroup!, profile = terminal.profile
                workspace.showFiles(); files = workspace.fileWindows.first
                guard let files, let first = files.selectedSession else { checks["fileWindowCreated"] = false; finish(); return }
                wait("toolbarSFTPOpensWithoutPassword", { first.connected && first.listedNames.contains("seed.txt") }) {
                    checks["fileSessionSharesExactTransport"] = first.connectionGroup === group && first.transientPassword == nil
                    // Exercise SFTP writes/reads and SCP on that same authenticated transport.
                    DispatchQueue.global().async {
                        var success = false
                        do {
                            let backend = try SFTPBackend(profile: profile, knownHosts: known, connectionGroup: group)
                            defer { backend.cancel() }
                            let source = root.appendingPathComponent("upload.txt"), downloaded = root.appendingPathComponent("download.txt")
                            try Data("file reuse fixture\n".utf8).write(to: source)
                            try backend.connect(); try backend.upload(source, to: "/upload.txt", progress: { _,_ in })
                            try backend.download("/upload.txt", to: downloaded, progress: { _,_ in })
                            let scp = try SCPTransfer(profile: profile, knownHosts: known, connectionGroup: group)
                            try scp.run(local: source, remote: "/scp.txt", upload: true)
                            let scpDownloaded = root.appendingPathComponent("scp-download.txt")
                            try scp.run(local: scpDownloaded, remote: "/scp.txt", upload: false)
                            let expected = try Data(contentsOf: source)
                            let sftpBytes = try Data(contentsOf: downloaded), scpBytes = try Data(contentsOf: scpDownloaded)
                            success = sftpBytes == expected && scpBytes == expected
                        } catch { success = false }
                        let transferred = success
                        DispatchQueue.main.async {
                            checks["sftpAndSCPShareTransport"] = transferred
                            guard transferred else { finish(); return }
                            let strip = descendants(files.window!.contentView!).compactMap { $0 as? TabStripView }.first!
                            strip.onDuplicate?(first.id)
                            wait("duplicateFileTabConnected", { files.sessions.count == 2 && files.sessions.allSatisfy(\.connected) }) {
                                let second = files.selectedSession!
                                checks["duplicateKeepsTransport"] = second.connectionGroup === group
                                terminal.shutdown(); workspace.closeTab()
                                first.cancelFileOperation()
                                let reconnect = descendants(first.view).compactMap { $0 as? NSButton }.first { $0.title == "重连" }!
                                reconnect.performClick(nil)
                                wait("reconnectAfterTerminalClosed", { first.connected && first.listedNames.contains("upload.txt") }) {
                                    checks["fileLeaseKeepsTransportAlive"] = group.isAvailable && workspace.tabs.isEmpty && second.connected
                                    try? Data().write(to: root.appendingPathComponent("deny-sftp"))
                                    files.open(profile, directory: ".", connectionGroup: group)
                                    let refused = files.selectedSession!
                                    wait("refusedSFTPFinishes", { !refused.hasActiveOperation }) {
                                        checks["refusalDoesNotCloseOtherChannels"] = !refused.connected && first.connected && second.connected && group.isAvailable
                                        files.closeTab(refused.id); try? FileManager.default.removeItem(at: root.appendingPathComponent("deny-sftp"))
                                        checks["noCredentialsWritten"] = (try? Data(contentsOf: workspace.store.url)) == before
                                        files.sessions.forEach { $0.shutdown() }
                                        wait("lastFileCloseReleasesMaster", { !FileManager.default.fileExists(atPath: group.directory.path) }) {
                                            checks["expiredTransportRejected"] = (try? SFTPBackend(profile: profile, knownHosts: known, connectionGroup: group)) == nil
                                            finish()
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
