// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum PasswordTest {
    static func run(_ controller: WorkspaceController) {
        guard let location = ProcessInfo.processInfo.environment["OSHELL_PASSWORD_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: location)
        do {
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("auth-fixture.json"))) as! [String: String]
            let password = fixture["password"]!, master = fixture["master"]!, user = fixture["user"]!
            var profile = SessionProfile(name: "加密密码登录测试", host: "127.0.0.1", port: 22230, username: user)
            profile.encryptedPassword = try SessionCipher.encrypt(password, master: master, profile: profile,
                                                                 identity: SSHIdentity(host: "127.0.0.1", user: user, port: 22230))
            controller.configuration.profiles = [profile]; try controller.store.save(controller.configuration)
            let saved = try controller.store.load().profiles[0]
            let configText = String(decoding: try Data(contentsOf: controller.store.url), as: UTF8.self)
            let knownHosts = controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts")
            try Data(contentsOf: root.appendingPathComponent("auth-known-hosts")).write(to: knownHosts)
            PasswordVault.shared.unlockForTesting(master)
            controller.open(saved)
            let pane = controller.selectedTab!.activePane
            try pane.startLogging(to: root.appendingPathComponent("auth-session.log"))
            var finished = false
            func finish(_ authenticated: Bool) {
                guard !finished else { return }; finished = true
                pane.stopLogging()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let log = String(decoding: (try? Data(contentsOf: root.appendingPathComponent("auth-session.log"))) ?? Data(), as: UTF8.self)
                    let result: [String: Any] = ["authenticated": authenticated,
                        "encryptedPasswordInConfiguration": configText.contains("AES-256-GCM") && configText.contains("ciphertext"),
                        "noPlaintextInConfiguration": !configText.contains(password) && !configText.contains(master),
                        "noPasswordInTerminalLog": !log.contains(password) && !log.contains(master)]
                    try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("auth-client-result.json"))
                    controller.shutdown(); PasswordVault.shared.lock(); NSApp.terminate(nil)
                }
            }
            let deadline = Date().addingTimeInterval(20)
            func check() {
                let text = String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                if text.contains("OSHELL_PASSWORD_AUTH_OK") { finish(true) }
                else if Date() > deadline || pane.ended { finish(false) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check) }
            }
            check()
        } catch { print("Password fixture setup failed"); controller.shutdown(); NSApp.terminate(nil) }
    }
}
