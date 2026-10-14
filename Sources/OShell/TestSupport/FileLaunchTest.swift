// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum FileLaunchTest {
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_FILE_LAUNCH_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        var checks = [String: Bool](), finished = false
        var diagnostics = [String](), monitor: Timer?
        var expectedUploadConfirmation = false
        func finish() {
            guard !finished else { return }; finished = true
            monitor?.invalidate()
            let sessions = controller.fileWindows.flatMap(\.sessions)
            controller.shutdown()
            checks["transientCredentialsReleasedOnClose"] = sessions.allSatisfy { $0.transientPassword == nil }
            checks["noUnexpectedDialogs"] = diagnostics.isEmpty
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "diagnostics": diagnostics]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("launch-result.json"))
            NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ next: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(35)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; next() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll) }
            }; poll()
        }
        do {
            monitor = Timer(timeInterval: 0.1, repeats: true) { _ in
                guard let window = NSApp.modalWindow else { return }
                func labels(_ view: NSView) -> [String] {
                    let own = (view as? NSTextField).flatMap { $0 is NSSecureTextField ? nil : $0.stringValue }.map { [$0] } ?? []
                    return own + view.subviews.flatMap(labels)
                }
                let message = window.contentView.map { labels($0).joined(separator: " | ") } ?? "modal"
                if expectedUploadConfirmation && message.hasPrefix("上传 1 个项目") {
                    expectedUploadConfirmation = false; NSApp.stopModal(withCode: .alertFirstButtonReturn); return
                }
                diagnostics.append(message)
                _ = PopupKeyboard.dismiss(window: window)
            }
            RunLoop.main.add(monitor!, forMode: .common); RunLoop.main.add(monitor!, forMode: .modalPanel)
            try controller.store.save(controller.configuration)
            let before = try Data(contentsOf: controller.store.url)
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
            try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: root.appendingPathComponent("app.pid"))
            wait("threeFileLaunchesConnected", {
                let sessions = controller.fileWindows.flatMap(\.sessions)
                return sessions.count == 3 && sessions.allSatisfy { $0.connected && !$0.hasActiveOperation && $0.listedNames.contains("seed.txt") }
            }) {
                let manager = controller.fileWindows[0], sessions = manager.sessions
                checks["oneFileWindowNoTerminalTabs"] = controller.fileWindows.count == 1 && controller.tabs.isEmpty
                checks["protocolDispatch"] = sessions.filter { $0.profile?.kind == .sftp }.count == 2 && sessions.filter { $0.profile?.kind == .ftp }.count == 1
                checks["titlesOnlyContainIP"] = sessions.allSatisfy { $0.tabTitle == "127.0.0.1" }
                checks["credentialsNotPersisted"] = (try? Data(contentsOf: controller.store.url)) == before && sessions.allSatisfy { $0.profile?.encryptedPassword == nil }
                let sftp = sessions.first { $0.profile?.kind == .sftp }!, ftp = sessions.first { $0.profile?.kind == .ftp }!
                let source = root.appendingPathComponent("launch-中文.txt")
                try? Data("launch upload payload".utf8).write(to: source)
                expectedUploadConfirmation = true; sftp.upload([source], to: "/")
                checks["busyTitleRemainsIP"] = sftp.tabTitle == "127.0.0.1"
                wait("sftpUploadFromLaunchedSession", { !sftp.hasActiveOperation && sftp.listedNames.contains(source.lastPathComponent) }) {
                    let ftpSource = root.appendingPathComponent("ftp-launch.txt"); try? Data("FTP payload".utf8).write(to: ftpSource)
                    expectedUploadConfirmation = true; ftp.upload([ftpSource], to: "/")
                    wait("ftpUploadFromLaunchedSession", { !ftp.hasActiveOperation && ftp.listedNames.contains(ftpSource.lastPathComponent) }) {
                        // The direct-URL connection remains independent when a sibling closes.
                        manager.closeTab(sftp.id)
                        checks["closeOneKeepsOtherConnections"] = manager.sessions.count == 2 && manager.sessions.allSatisfy(\.connected)
                        checks["closedSessionDropsCredential"] = sftp.transientPassword == nil
                        finish()
                    }
                }
            }
        } catch { checks["setup"] = false; finish() }
    }
}
