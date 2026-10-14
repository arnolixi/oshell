// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Real SSH + Bash/lrz, including peers which omit CAN or delay recovery output.
final class ZmodemCancelTest {
    private static var active: ZmodemCancelTest?
    private let controller: WorkspaceController, root: URL
    private var pane: TerminalPane!
    private var checks = [String: Bool](), failures = [String](), finished = false
    private var originalPID: pid_t = 0
    init(_ controller: WorkspaceController, root: URL) { self.controller = controller; self.root = root }
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_CANCEL_TEST_ROOT"] else { return }
        let test = ZmodemCancelTest(controller, root: URL(fileURLWithPath: path)); active = test; test.start()
    }
    private var text: String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
    private func send(_ value: String) { pane.terminal.process.send(data: Array((value + "\r").utf8)[...]) }
    private func wait(_ label: String, _ condition: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(15)
        func poll() {
            guard !self.finished else { return }
            if condition() { self.checks[label] = true; then() }
            else if self.pane.ended || Date() > deadline { self.failures.append(label); self.finish() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
        }
        poll()
    }
    private func start() {
        do {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as! [String: Any]
            var profile = SessionProfile(name: "rz cancellation fixture", host: "127.0.0.1", port: fixture["port"] as! Int, username: "fixture")
            let master = "isolated-zmodem-cancel-fixture"
            profile.encryptedPassword = try SessionCipher.encrypt(fixture["password"] as! String, master: master, profile: profile, identity: SSHIdentity(host: profile.host, user: profile.username, port: profile.port))
            try FileManager.default.createDirectory(at: controller.store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: root.appendingPathComponent("known_hosts")).write(to: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
            PasswordVault.shared.unlockForTesting(master)
            controller.open(profile); pane = controller.selectedTab!.activePane
            pane.onError = { [weak self] message in self?.failures.append(message); self?.finish() }
            wait("sshReady", { self.text.contains("CANCEL_TEST> ") }) {
                self.originalPID = self.pane.terminal.process.shellPid; self.cancelRound(0)
            }
        } catch { failures.append(error.localizedDescription); finish() }
    }
    private func cancelRound(_ round: Int) {
        guard round < 3 else { transferAgain(); return }
        try? Data(String(round).utf8).write(to: root.appendingPathComponent("cancel-mode"))
        send("rz")
        wait("chooser\(round)", { self.pane.transferChooserForTesting != nil }) {
            self.checks["noHelperBeforeSelection\(round)"] = self.pane.transferDiagnosticState.hasPrefix("no helper")
            if round == 1 { self.pane.transferProgress.cancelButton.performClick(nil) }
            else { self.pane.transferChooserForTesting?.cancel(nil) }
            // Exercise the old two-second disconnect deadline, even if output is delayed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard !self.finished else { return }
                self.checks["sameSSHAfterCancel\(round)"] = !self.pane.ended && self.pane.terminal.process.running && self.pane.terminal.process.shellPid == self.originalPID
                self.checks["pickerClosed\(round)"] = self.pane.transferChooserForTesting == nil
                self.checks["cancelCompleted\(round)"] = !self.pane.isTransferring
                guard self.checks["sameSSHAfterCancel\(round)"] == true else { self.finish(); return }
                self.send("printf '\\nCANCEL_READY_\(round)\\n'")
                self.wait("inputWorks\(round)", { self.text.contains("\nCANCEL_READY_\(round)\n") }) { self.cancelRound(round + 1) }
            }
        }
    }
    private func transferAgain() {
        try? Data("0".utf8).write(to: root.appendingPathComponent("cancel-mode"))
        let source = root.appendingPathComponent("payload.bin"), destination = root.appendingPathComponent("remote/payload.bin"), download = root.appendingPathComponent("download")
        let payload = Data((0..<65536).map { UInt8($0 % 251) })
        do { try payload.write(to: source); try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true) }
        catch { failures.append(error.localizedDescription); finish(); return }
        pane.transferSelection = { direction in direction == .upload ? ([source], nil) : ([], download) }
        send("rz")
        wait("uploadAfterCancel", { (try? Data(contentsOf: destination)) == payload && !self.pane.isTransferring }) {
            self.send("sz payload.bin")
            self.wait("downloadAfterCancel", { (try? Data(contentsOf: download.appendingPathComponent("payload.bin"))) == payload && !self.pane.isTransferring }) {
                self.checks["sameSSHAfterTransfers"] = self.pane.terminal.process.shellPid == self.originalPID && !self.pane.ended
                self.finish()
            }
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true
        let report: [String: Any] = ["passed": failures.isEmpty && checks.values.allSatisfy { $0 }, "checks": checks, "failures": failures]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        controller.shutdown(); PasswordVault.shared.lock(); NSApp.terminate(nil); Self.active = nil
    }
}
