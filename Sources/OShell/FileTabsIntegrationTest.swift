// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum FileTabsIntegrationTest {
    static func run(_ controller: WorkspaceController) {
        guard let location = ProcessInfo.processInfo.environment["OSHELL_FILE_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: location)
        var checks = [String: Bool](), finished = false
        var manager: RemoteFileWindow?
        func finish() {
            guard !finished else { return }; finished = true; manager?.close(); controller.shutdown()
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("file-result.json"))
            print(report); PasswordVault.shared.lock(); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ action: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(25)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; action() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() } }
            }; poll()
        }
        do {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
            let password = fixture["password"] as! String, master = fixture["master"] as! String
            var sftp = SessionProfile(name: "SFTP A", group: "", kind: .sftp, host: "127.0.0.1", port: fixture["sshPort"] as! Int, username: fixture["user"] as! String)
            sftp.initialDirectory = "/"
            sftp.encryptedPassword = try SessionCipher.encrypt(password, master: master, profile: sftp, identity: SSHIdentity(host: sftp.host, user: sftp.username, port: sftp.port))
            var ftp = SessionProfile(name: "FTP B", group: "", kind: .ftp, host: "127.0.0.1", port: fixture["ftpPort"] as! Int, username: sftp.username)
            ftp.initialDirectory = "/"
            ftp.encryptedPassword = try SessionCipher.encrypt(password, master: master, profile: ftp, identity: SSHIdentity(host: ftp.host, user: ftp.username, port: ftp.port))
            checks["unifiedCatalogSaved"] = controller.saveConfiguration(Configuration(profiles: [sftp, ftp]))
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
            PasswordVault.shared.unlockForTesting(master)
            controller.open(sftp)
            guard let files = controller.fileWindows.first else { throw ModelError.invalid("文件窗口未创建") }
            manager = files; let first = files.selectedSession!
            controller.open(ftp); let second = files.selectedSession!
            controller.open(sftp); let third = files.selectedSession!
            checks["protocolDispatchUsesOneFileWindow"] = controller.fileWindows.count == 1 && controller.tabs.isEmpty && files.sessions.count == 3
            wait("threeRealConnections", { [first, second, third].allSatisfy(\.connected) }) {
                checks["threeListsIndependent"] = [first, second, third].allSatisfy { $0.listedNames.contains("seed.txt") }
                first.navigate("/tab-a"); second.navigate("/tab-b")
                wait("concurrentDirectories", { first.directory == "/tab-a" && second.directory == "/tab-b" }) {
                    files.select(first); first.filterText = "a-only"
                    files.select(second); second.filterText = "b-only"
                    checks["independentDirectoryAndFilter"] = first.listedNames == ["a-only.txt"] && second.listedNames == ["b-only.txt"] && third.directory == "/"
                    third.cancelFileOperation(); files.closeTab(third.id)
                    first.filterText = ""; second.filterText = ""; first.navigate("/"); second.navigate("/")
                    wait("peersStillUsableAfterClose", { first.directory == "/" && second.directory == "/" && !first.hasActiveOperation && !second.hasActiveOperation }) {
                        checks["closedTabNotResurrected"] = files.sessions.count == 2 && third.closed
                        let config = (try? String(contentsOf: controller.store.url, encoding: .utf8)) ?? ""
                        checks["noPlaintextCredentials"] = !config.isEmpty && !config.contains(password) && !config.contains(master)
                        finish()
                    }
                }
            }
        } catch { checks["setup"] = false; print(error.localizedDescription); finish() }
    }
}
