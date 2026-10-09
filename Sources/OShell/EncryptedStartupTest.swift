// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum EncryptedStartupTest {
    private static var timer: Timer?, original: Data?, attempts = 0, wrongRejected = false
    private static let master = "dav-master-fixture-2026"
    static func install() {
        guard let directory = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] else { return }
        let file = URL(fileURLWithPath: directory).appendingPathComponent("configuration.json")
        original = try? Data(contentsOf: file)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let value = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard let window = NSApp.modalWindow, let root = window.contentView else { return }
            if let field = descendants(root).compactMap({ $0 as? NSSecureTextField }).first {
                field.stringValue = attempts == 0 ? "incorrect-fixture" : master; attempts += 1
                descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "确定" }?.performClick(nil)
            } else {
                let text = descendants(root).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: " ")
                if text.contains("主密码不正确") {
                    wrongRejected = (try? Data(contentsOf: file)) == original
                    _ = PopupKeyboard.dismiss(window: window)
                }
            }
        }
        timer = value; RunLoop.main.add(value, forMode: .common); RunLoop.main.add(value, forMode: .modalPanel)
    }
    static func complete(_ workspace: WorkspaceController) {
        timer?.invalidate(); timer = nil
        let checks = ["wrongMasterRejectedWithoutWriting":wrongRejected, "promptedAgain":attempts >= 2,
                      "encryptedDataUnlocked":workspace.isSecurityUnlocked && workspace.store.encryptedStorage,
                      "savedProfilesLoaded":workspace.configuration.profiles.contains { $0.name == "dav-a" },
                      "masterKeptOnlyInMemory":PasswordVault.shared.cachedMaster == master]
        if let path = ProcessInfo.processInfo.environment["OSHELL_STARTUP_VAULT_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: ["passed":checks.values.allSatisfy { $0 }, "checks":checks], options:[.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath:path))
        }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
