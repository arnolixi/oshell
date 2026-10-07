// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// End-to-end tests against disposable loopback SFTP/SCP/FTP servers.
enum FileFeatureTest {
    static func run(_ controller: WorkspaceController) {
        guard let location = ProcessInfo.processInfo.environment["OSHELL_FILE_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: location)
        do {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
            let password = fixture["password"] as! String, master = fixture["master"] as! String
            var profile = SessionProfile(name: "文件测试", host: "127.0.0.1", port: fixture["sshPort"] as! Int, username: fixture["user"] as! String)
            profile.encryptedPassword = try SessionCipher.encrypt(password, master: master, profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
            var ftp = FTPProfile(); ftp.name = "FTP 测试"; ftp.host = "127.0.0.1"; ftp.port = fixture["ftpPort"] as! Int; ftp.username = profile.username
            ftp.encryptedPassword = try SessionCipher.encrypt(password, master: master, profile: ftp.credentialProfile, identity: SSHIdentity(host: ftp.host, user: ftp.username, port: ftp.port))
            controller.configuration.profiles = [profile]; controller.configuration.ftpProfiles = [ftp]; try controller.store.save(controller.configuration)
            let known = controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts")
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: known)
            PasswordVault.shared.unlockForTesting(master)
            let sftp = try SFTPBackend(profile: profile, knownHosts: known), ftpBackend = FTPBackend(profile: ftp, password: password), scp = try SCPTransfer(profile: profile, knownHosts: known)
            DispatchQueue.global(qos: .userInitiated).async {
                var checks = [String: Bool](), failures = [String]()
                let local = root.appendingPathComponent("local")
                do {
                    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                    let payload = Data((0..<262144).map { UInt8($0 % 256) }), source = local.appendingPathComponent("中文 'quoted' file.bin")
                    try payload.write(to: source)
                    let tree = local.appendingPathComponent("tree"); try FileManager.default.createDirectory(at: tree.appendingPathComponent("子目录"), withIntermediateDirectories: true)
                    try Data("hidden".utf8).write(to: tree.appendingPathComponent(".env")); try payload.prefix(4096).write(to: tree.appendingPathComponent("子目录/a b.bin"))
                    for (name, backend) in [("sftp", sftp as RemoteFileBackend), ("ftp", ftpBackend as RemoteFileBackend)] {
                        try backend.connect(); checks[name + "ConnectAndList"] = try backend.list("/").contains { $0.name == "seed.txt" }
                        let directory = "/" + name + "-test"; try backend.mkdir(directory)
                        let remote = RemotePath.join(directory, source.lastPathComponent)
                        try backend.upload(source, to: remote) { _, _ in }
                        let received = local.appendingPathComponent(name + "-download.bin")
                        try backend.download(remote, to: received) { _, _ in }
                        checks[name + "BinaryUnicodeRoundTrip"] = try Data(contentsOf: received) == payload
                        let renamed = directory + "/renamed.bin"; try backend.rename(remote, to: renamed)
                        checks[name + "Rename"] = try backend.list(directory).contains { $0.name == "renamed.bin" }
                        try backend.upload(tree, to: directory + "/tree") { _, _ in }
                        let downloadedTree = local.appendingPathComponent(name + "-tree")
                        try backend.download(directory + "/tree", to: downloadedTree) { _, _ in }
                        let hidden = try Data(contentsOf: downloadedTree.appendingPathComponent(".env")), nested = try Data(contentsOf: downloadedTree.appendingPathComponent("子目录/a b.bin"))
                        checks[name + "RecursiveHiddenRoundTrip"] = hidden == Data("hidden".utf8) && nested == payload.prefix(4096)
                        try backend.remove(renamed, directory: false)
                        checks[name + "DeleteFile"] = try !backend.list(directory).contains { $0.name == "renamed.bin" }
                        try backend.mkdir(directory + "/empty"); try backend.remove(directory + "/empty", directory: true)
                        checks[name + "DeleteEmptyDirectory"] = try !backend.list(directory).contains { $0.name == "empty" }
                    }
                    try ftpBackend.mkdir("/list-only")
                    try ftpBackend.mkdir("/list-only/subdir")
                    try ftpBackend.upload(source, to: "/list-only/test.bin") { _, _ in }
                    let fallback = try ftpBackend.list("/list-only")
                    checks["ftpUnixListFallback"] = fallback.contains { $0.name == "subdir" && $0.directory } && fallback.contains { $0.name == "test.bin" && $0.size == UInt64(payload.count) }
                    let dos = try FTPBackend.parseLIST(Data("10-06-26  08:00AM       <DIR>          folder name\r\n10-06-26  08:00AM               12     file name.txt\r\n".utf8))
                    checks["ftpDOSListParsing"] = dos.count == 2 && dos[0].directory && dos[1].size == 12
                    try sftp.upload(source, to: "/exclusive.bin") { _, _ in }
                    do { try sftp.upload(source, to: "/exclusive.bin") { _, _ in }; checks["sftpDoesNotOverwrite"] = false } catch { checks["sftpDoesNotOverwrite"] = true }
                    try scp.run(local: source, remote: "/scp 'quote' file.bin", upload: true)
                    let scpOutput = local.appendingPathComponent("scp-download.bin")
                    try scp.run(local: scpOutput, remote: "/scp 'quote' file.bin", upload: false)
                    checks["scpRoundTripAndRepeatedAuthentication"] = try Data(contentsOf: scpOutput) == payload
                    let sftpPartial = local.appendingPathComponent("cancel-sftp.bin")
                    do { try sftp.download("/slow.bin", to: sftpPartial) { bytes, _ in if bytes >= 32768 { sftp.cancel() } }; checks["sftpCancel"] = false } catch { checks["sftpCancel"] = !FileManager.default.fileExists(atPath: sftpPartial.path) }
                    let ftpPartial = local.appendingPathComponent("cancel-ftp.bin")
                    do { try ftpBackend.download("/slow.bin", to: ftpPartial) { bytes, _ in if bytes >= 32768 { ftpBackend.cancel() } }; checks["ftpCancel"] = false } catch { checks["ftpCancel"] = !FileManager.default.fileExists(atPath: ftpPartial.path) }
                    let config = String(decoding: try Data(contentsOf: controller.store.url), as: UTF8.self)
                    checks["noPlaintextCredentialsInConfiguration"] = !config.contains(password) && !config.contains(master)
                } catch { failures.append(error.localizedDescription) }
                sftp.cancel(); ftpBackend.cancel()
                let result: [String: Any] = ["passed": failures.isEmpty && checks.values.allSatisfy { $0 }, "checks": checks, "failures": failures]
                try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("file-result.json"))
                print(result)
                DispatchQueue.main.async {
                    scp.cancel()
                    if CommandLine.arguments.contains("--keep-open") {
                        controller.newLocal(); controller.newLocal()
                        for pane in controller.inputPanes {
                            let sample = ConnectionValidation.quote("ERROR warning " + pane.title)
                            pane.terminal.process.send(data: Array(("printf '%s\\n' " + sample + "\r").utf8)[...])
                        }
                        controller.openFiles(for: profile)
                    } else { controller.shutdown(); PasswordVault.shared.lock(); NSApp.terminate(nil) }
                }
            }
        } catch { print(error); controller.shutdown(); NSApp.terminate(nil) }
    }
}
