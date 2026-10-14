// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// Real shell + lsz + lrz regression, optionally with a retransmitting receiver
/// supplied through OSHELL_HELPERS. Never connects to a user's remote host.
final class ZmodemRegressionTest {
    private static var active: ZmodemRegressionTest?
    private let controller: WorkspaceController
    private let root: URL
    private var pane: TerminalPane!
    private var failures = [String]()
    private var results = [[String: Any]]()
    private var finished = false
    private let prompt = ProcessInfo.processInfo.environment["OSHELL_FINISH_MODE"] == "missing-oo" ? "test@\(LocalHostIdentity.current().hostname):~$ " : "ZMODEM_TEST> "
    private let sequence = ProcessInfo.processInfo.environment["OSHELL_ZMODEM_SEQUENCE"] == "1"
    private let sizes = ProcessInfo.processInfo.environment["OSHELL_ZMODEM_LARGE"] == "1" ? [12_993_548] : [0, 1, 6, 128, 4096, 65536]
    init(_ controller: WorkspaceController, root: URL) { self.controller = controller; self.root = root }
    static func run(_ controller: WorkspaceController) {
        guard let path = ProcessInfo.processInfo.environment["OSHELL_ZMODEM_TEST_ROOT"] else { return }
        let test = ZmodemRegressionTest(controller, root: URL(fileURLWithPath: path)); active = test
        test.start()
    }
    private var text: String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
    private func send(_ command: String) { pane.terminal.process.send(data: Array((command + "\r").utf8)[...]) }
    private func wait(_ label: String, condition: @escaping () -> Bool, then action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(35)
        func poll() {
            guard !self.finished else { return }
            if condition() { action() }
            else if Date() > deadline || self.pane.ended { self.failures.append(label + " timed out"); self.finish() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
        }
        poll()
    }
    private func start() {
        do {
            for name in ["source", "download"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
            controller.newLocal(); pane = controller.selectedTab!.activePane
            pane.transferSelection = { [weak self] direction in
                guard let self else { return nil }
                return direction == .upload ? ([self.root.appendingPathComponent("source/1.txt")], nil) : ([], self.root.appendingPathComponent("download"))
            }
            pane.onError = { [weak self] message in self?.failures.append(message); self?.finish() }
            try pane.startLogging(to: root.appendingPathComponent("terminal.log"))
            send("export PS1=\(ConnectionValidation.quote(prompt)); exec /bin/bash --noprofile --norc -i")
            wait("bash", condition: { self.text.contains("\n" + self.prompt) }) { self.next(0) }
        } catch { failures.append(error.localizedDescription); finish() }
    }
    private func next(_ index: Int) {
        guard index < sizes.count * 2 else { finish(); return }
        guard sequence else { download(index); return }
        let source = root.appendingPathComponent("source/1.txt")
        let destination = root.appendingPathComponent("remote-\(index)")
        let expected = Data((0..<sizes[index % sizes.count]).map { UInt8($0 % 251) })
        do {
            try expected.write(to: source)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch { failures.append(error.localizedDescription); finish(); return }
        let helper = ZmodemTransfer.helperDirectory.appendingPathComponent("lrz")
        send("cd \(ConnectionValidation.quote(destination.path)); \(ConnectionValidation.quote(helper.path))")
        wait("upload \(index)", condition: { (try? Data(contentsOf: destination.appendingPathComponent("1.txt"))) == expected && !self.pane.isTransferring }) {
            self.download(index)
        }
    }
    private func download(_ index: Int) {
        guard index < sizes.count * 2 else { finish(); return }
        let source = root.appendingPathComponent(sequence ? "remote-\(index)/1.txt" : "source/1.txt")
        let expected = Data((0..<sizes[index % sizes.count]).map { UInt8($0 % 251) })
        do { if !sequence { try expected.write(to: source) } } catch { failures.append(error.localizedDescription); finish(); return }
        let helper = ZmodemTransfer.helperDirectory.appendingPathComponent("lsz")
        send("\(ConnectionValidation.quote(helper.path)) -- \(ConnectionValidation.quote(source.path))")
        let target = root.appendingPathComponent("download/1.txt" + (index == 0 ? "" : ".\(index - 1)"))
        var fileCompleteAt: Date?
        wait("download \(index)", condition: {
            let complete = (try? Data(contentsOf: target)) == expected
            if complete, fileCompleteAt == nil { fileCompleteAt = Date() }
            return complete && !self.pane.isTransferring
        }) {
            self.send("printf '\\nZMODEM_ROUND_\(index)_READY\\n'")
            self.wait("shell recovery \(index)", condition: { self.text.contains("\nZMODEM_ROUND_\(index)_READY\n") }) {
                let clean = !self.text.contains("command not found") && !self.text.contains("0800000000022d") && !self.text.contains("OOZMODEM_TEST")
                let recoverySeconds = Date().timeIntervalSince(fileCompleteAt ?? Date())
                self.results.append(["bytes": expected.count, "contentMatches": true, "shellClean": clean, "recoverySeconds": recoverySeconds])
                if recoverySeconds > 3 { self.failures.append("Slow recovery after download \(index): \(recoverySeconds)s"); self.finish(); return }
                if !clean { self.failures.append("ZFIN leaked into Bash in round \(index)"); self.finish() }
                else { self.next(index + 1) }
            }
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true
        pane?.stopLogging()
        if pane != nil { try? Data(text.utf8).write(to: root.appendingPathComponent("screen.txt")) }
        let report: [String: Any] = ["passed": failures.isEmpty, "rounds": results, "failures": failures]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        print(report); controller.shutdown(); NSApp.terminate(nil); Self.active = nil
    }
}
