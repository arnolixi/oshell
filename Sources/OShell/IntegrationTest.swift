// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Optional developer checks run through the same SSH, PTY, parser, logger and transfer code as the app.
final class IntegrationTest {
    private static var active: IntegrationTest?
    let controller: WorkspaceController
    let root: URL
    let directory: URL
    var results = [String: Any]()
    var errors = [String]()
    var remotePane: TerminalPane!
    var sourceFile: URL!
    init(_ controller: WorkspaceController, root: URL) {
        self.controller = controller; self.root = root
        self.directory = root.appendingPathComponent("integration-\(UUID().uuidString)")
    }
    static func run(_ controller: WorkspaceController) {
        guard let root = ProcessInfo.processInfo.environment["OSHELL_INTEGRATION_ROOT"] else { return }
        let test = IntegrationTest(controller, root: URL(fileURLWithPath: root)); active = test
        do { try test.start() } catch { test.fail(error.localizedDescription) }
    }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func send(_ command: String) { remotePane.terminal.process.send(data: Array((command + "\r").utf8)[...]) }
    private var text: String { String(decoding: remotePane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
    private func wait(_ label: String, timeout: Double = 20, condition: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if condition() { self.results[label] = true; then() }
            else if Date() > deadline { self.fail("\(label) 超时") }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check) }
        }
        check()
    }
    private func start() throws {
        let fixture = root.appendingPathComponent("ssh-fixture")
        for name in ["source", "remote", "download"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        sourceFile = directory.appendingPathComponent("source/中文 空格.bin")
        try Data((0..<1024*1024).map { UInt8($0 % 256) }).write(to: sourceFile)
        try Data("OSHELL_TEST=1\n".utf8).write(to: directory.appendingPathComponent("source/.env"))
        let knownHosts = controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: fixture.appendingPathComponent("known_hosts")).write(to: knownHosts)
        let profile = SessionProfile(name: "SSH 集成测试", group: "测试", host: "127.0.0.1", port: 22229,
                                     username: NSUserName(), identityFile: fixture.appendingPathComponent("client_key").path)
        controller.open(profile); remotePane = controller.selectedTab!.activePane
        remotePane.onError = { [weak self] message in self?.fail(message) }
        remotePane.transferSelection = { [weak self] direction in
            guard let self else { return nil }
            return direction == .upload ? ([self.sourceFile, self.directory.appendingPathComponent("source/.env")], nil) : ([], directory.appendingPathComponent("download"))
        }
        try remotePane.startLogging(to: directory.appendingPathComponent("terminal.log"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.send("printf '\\nOSHELL_SSH_MARKER\\n'")
            self.wait("sshRoundTrip", condition: { self.text.contains("\nOSHELL_SSH_MARKER\n") }, then: self.enterBash)
        }
    }
    private func enterBash() {
        send("export PS1='OSHELL_BASH> '; exec /bin/bash --noprofile --norc -i")
        wait("bashReady", condition: { self.text.contains("\nOSHELL_BASH> ") }, then: upload)
    }
    private func upload() {
        let helper = ZmodemTransfer.helperDirectory.appendingPathComponent("lrz").path
        let destination = directory.appendingPathComponent("remote")
        send("cd \(quote(destination.path)); \(quote(helper)) -b; printf '\\nOSHELL_UPLOAD_DONE\\n'")
        let received = destination.appendingPathComponent(sourceFile.lastPathComponent)
        wait("zmodemUpload", condition: {
            self.sameContent(received) && self.dotFileMatches(destination) && !self.remotePane.isTransferring
        }, then: download)
    }
    private func download() {
        let helper = ZmodemTransfer.helperDirectory.appendingPathComponent("lsz").path
        send("\(quote(helper)) -b -e -f -- \(quote(sourceFile.path)) \(quote(directory.appendingPathComponent("source/.env").path)); printf '\\nOSHELL_DOWNLOAD_DONE\\n'")
        let received = directory.appendingPathComponent("download").appendingPathComponent(sourceFile.lastPathComponent)
        wait("zmodemDownload", condition: { self.sameContent(received) && self.dotFileMatches(self.directory.appendingPathComponent("download")) && !self.remotePane.isTransferring }) { self.tinyDownloads(0) }
    }
    private func tinyDownloads(_ index: Int) {
        guard index < 15 else { results["repeatedTinySzWithoutShellErrors"] = !text.contains("command not found"); cancellation(); return }
        let sizes = [0, 1, 6, 128, 4096]
        let data = Data(repeating: 65, count: sizes[index % sizes.count])
        let source = directory.appendingPathComponent("source/1.txt")
        do { try data.write(to: source) } catch { fail(error.localizedDescription); return }
        let helper = ZmodemTransfer.helperDirectory.appendingPathComponent("lsz").path
        send("\(quote(helper)) -- \(quote(source.path))") // Match plain `sz 1.txt`, without -e/-b test-only flags.
        let target = directory.appendingPathComponent("download/1.txt" + (index == 0 ? "" : ".\(index - 1)"))
        wait("smallSz\(index)", condition: { (try? Data(contentsOf: target)) == data && !self.remotePane.isTransferring }) {
            self.send("printf '\\nTINY_READY_\(index)\\n'")
            self.wait("smallSzPrompt\(index)", condition: { self.text.contains("\nTINY_READY_\(index)\n") }) { self.tinyDownloads(index + 1) }
        }
    }
    private func cancellation() {
        remotePane.transferSelection = { [weak self] _ in guard let self else { return nil }; return ([self.sourceFile], nil) }
        let helper = ZmodemTransfer.helperDirectory.appendingPathComponent("lrz").path
        send("\(quote(helper)) -b; printf '\\nOSHELL_CANCEL_DONE\\n'")
        wait("transferStartedForCancel", condition: { self.remotePane.isTransferring }) {
            self.remotePane.cancelTransfer()
            self.wait("cancelReturnedToTerminal", condition: { !self.remotePane.isTransferring }) {
                self.send("printf '\\nOSHELL_RECOVERED\\n'")
                self.wait("terminalRecoveredAfterCancel", condition: { self.text.contains("\nOSHELL_RECOVERED\n") }) {
                    self.cancelDownload()
                }
            }
        }
    }
    private func cancelDownload() {
        do {
            let file = directory.appendingPathComponent("source/cancel-data.bin")
            let marker = "OSHELL_BINARY_PAYLOAD_DO_NOT_LOG_"
            try Data(String(repeating: marker, count: 262144).utf8).write(to: file)
            remotePane.transferSelection = { [weak self] _ in guard let self else { return nil }; return ([], self.directory.appendingPathComponent("download")) }
            let helper = ZmodemTransfer.helperDirectory.appendingPathComponent("lsz").path
            send("\(quote(helper)) -b -e -w 16384 -- \(quote(file.path)); printf '\\nOSHELL_DOWNLOAD_CANCEL_DONE\\n'")
            wait("downloadStartedForCancel", condition: { self.remotePane.isTransferring }) {
                self.remotePane.cancelTransfer()
                self.wait("downloadCancelReturnedToTerminal", condition: { !self.remotePane.isTransferring }) {
                    self.send("printf '\\nOSHELL_DOWNLOAD_RECOVERED\\n'")
                    self.wait("downloadRecoveredAfterCancel", condition: { self.text.contains("\nOSHELL_DOWNLOAD_RECOVERED\n") }) {
                        self.remotePane.stopLogging(); self.layoutChecks()
                    }
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func sameContent(_ url: URL) -> Bool {
        guard let received = try? Data(contentsOf: url), let original = try? Data(contentsOf: sourceFile) else { return false }
        return received.count == original.count && PlatformDigest.sha256(received) == PlatformDigest.sha256(original)
    }
    private func dotFileMatches(_ folder: URL) -> Bool {
        (try? Data(contentsOf: folder.appendingPathComponent(".env"))) == Data("OSHELL_TEST=1\n".utf8)
    }
    private func layoutChecks() {
        controller.newLocal(); controller.splitVertical(); controller.splitHorizontal()
        let tab = controller.selectedTab!
        for pane in tab.layout.panes {
            pane.terminal.process.send(data: Array("/usr/bin/awk 'BEGIN {for(i=0;i<30000;i++) print \"OSHELL_LOAD_\" i}'\r".utf8)[...])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.results["nativeSplits"] = tab.layout.panes.count == 3 && tab.layout.panes.allSatisfy { $0.view.window != nil && $0.view.bounds.width > 50 && $0.view.bounds.height > 50 }
            self.results["terminalSearch"] = tab.activePane.terminal.findNext("OSHELL_LOAD_29999")
            var durations = [Double]()
            for _ in 0..<100 {
                let start = DispatchTime.now().uptimeNanoseconds
                self.controller.nextTab()
                durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            self.results["switchMeanMs"] = durations.reduce(0, +) / 100
            self.results["switchP95Ms"] = durations.sorted()[94]
            self.results["switchMaxMs"] = durations.max()
            self.results["snapshot"] = self.controller.diagnosticSnapshot
            let log = (try? Data(contentsOf: self.directory.appendingPathComponent("terminal.log"))) ?? Data()
            self.results["logRecordsText"] = String(decoding: log, as: UTF8.self).contains("OSHELL_SSH_MARKER")
            self.results["logExcludesBinary"] = !log.contains(0) && log.range(of: Data([42,42,24,66])) == nil && !String(decoding: log, as: UTF8.self).contains("OSHELL_BINARY_PAYLOAD_DO_NOT_LOG_")
            self.finish()
        }
    }
    private func fail(_ message: String) { errors.append(message); finish() }
    private func finish() {
        results["errors"] = errors
        results["passed"] = errors.isEmpty && !results.values.contains(where: { ($0 as? Bool) == false })
        if let bytes = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: root.appendingPathComponent("integration-result.json"))
            print(String(decoding: bytes, as: UTF8.self))
        }
        controller.shutdown(); NSApp.terminate(nil); Self.active = nil
    }
}
