// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

final class LoginPasswordSavingTest {
    private static var retained: LoginPasswordSavingTest?
    private let workspace: WorkspaceController
    private var checks = [String: Bool](), savedCount = 0, index = 0
    private var steps = [() -> Void](), brokers = [AuthBroker]()
    private var initialRevision = 0, pendingSaves = 0
    private let profile = SessionProfile(name: "登录保存测试", host: "192.0.2.44", username: "fixture")
    private let prompt = "fixture@192.0.2.44's password:"
    private init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = LoginPasswordSavingTest(workspace); retained = test; test.start()
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func advance() {
        DispatchQueue.main.async { [self] in
            guard pendingSaves == 0 else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.advance() }; return }
            guard index < steps.count else { finish(); return }
            FileHandle.standardOutput.write(Data("Login saving stage \(index)\n".utf8))
            let step = steps[index]; index += 1; step()
        }
    }
    private func request(_ broker: AuthBroker, prompt: String, hint: String = "", answer: String? = nil,
                         save: Bool = false, enabled: Bool? = nil, cancel: Bool = false, label: String = "", check: @escaping (AuthResponse?) -> Void = { _ in }) {
        var handled = false, finished = false
        let timer = Timer(timeInterval: 0.02, repeats: true) { [self] _ in
            guard let root = NSApp.modalWindow?.contentView else { return }
            let views = descendants(root)
            if let input = views.first(where: { $0.identifier?.rawValue == "ssh.auth.password" }) as? NSSecureTextField, !handled {
                handled = true
                let option = views.first { $0.identifier?.rawValue == "ssh.auth.savePassword" } as? NSButton
                checks[label + "DefaultNotSaved"] = option?.state == .off
                checks[label + "SaveOptionEnabled"] = option?.isEnabled == (enabled ?? save)
                if let answer { input.stringValue = answer }
                if save { option?.state = .on }
                if cancel, let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
                else { views.compactMap { $0 as? NSButton }.first { $0.title == "确定" }?.performClick(nil) }
            } else if views.compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.hasPrefix("SSH 已完成认证，但密码未保存") }) {
                if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
            }
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        let env = broker.environment
        DispatchQueue.global().async {
            let result = try? AuthIPC.request(socketPath: env["OSHELL_AUTH_SOCKET"]!, request: AuthRequest(token: env["OSHELL_AUTH_TOKEN"]!, prompt: prompt, hint: hint))
            DispatchQueue.main.async { [self] in
                guard !finished else { return }; finished = true; timer.invalidate(); check(result); advance()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in
            guard !finished else { return }; finished = true; timer.invalidate(); checks["requestTimeout-\(index)"] = false
            if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
            advance()
        }
    }
    private func broker(_ target: SessionProfile, existing: Bool, permitsSaving: Bool = true) throws -> AuthBroker {
        let value = try AuthBroker(profile: target, permitsSaving: permitsSaving)
        value.onSavePassword = { [self] profile, password, identity in
            pendingSaves += 1
            workspace.saveAuthenticatedPassword(password, profile: profile, identity: identity, requireExisting: existing) { [self] saved in
                if saved { savedCount += 1 }; pendingSaves -= 1
            }
        }
        brokers.append(value); return value
    }
    private func start() {
        do {
            var config = workspace.configuration; config.profiles = [profile]; _ = workspace.saveConfiguration(config)
            initialRevision = workspace.configurationRevision
            let first = try broker(profile, existing: true)
            steps.append { [self] in request(first, prompt: prompt, answer: "rejected-fixture", save: true, label: "rejected") { [self] in
                checks["inputSentOnlyToSSH"] = $0?.answer == "rejected-fixture"
                checks["notSavedBeforeAuthentication"] = workspace.configurationRevision == initialRevision && savedCount == 0
            } }
            steps.append { [self] in request(first, prompt: prompt, answer: "ignored-fixture", save: true, cancel: true, label: "cancel") }
            steps.append { [self] in request(first, prompt: "", hint: "oshell-session-ready") }
            steps.append { [self] in checks["cancelNeverPersistsRejectedPassword"] = savedCount == 0 && workspace.configurationRevision == initialRevision; advance() }
            steps.append { [self] in request(first, prompt: prompt, answer: "unsaved-fixture", enabled: true, label: "unchecked") }
            steps.append { [self] in request(first, prompt: "", hint: "oshell-session-ready") }
            steps.append { [self] in checks["uncheckedPasswordNeverSaved"] = savedCount == 0; advance() }
            steps.append { [self] in request(first, prompt: prompt, answer: "accepted-fixture", save: true, label: "accepted") }
            steps.append { [self] in request(first, prompt: "", hint: "oshell-session-ready") }
            steps.append { [self] in
                let stored = workspace.configuration.profiles[0]
                checks["savesAfterReadySignal"] = savedCount == 1 && stored.encryptedPassword?.localKeyID != nil
                checks["savedPasswordDecrypts"] = (try? PasswordVault.shared.readSavedPassword(stored)) == "accepted-fixture"
                let disk = String(decoding: (try? Data(contentsOf: workspace.store.url)) ?? Data(), as: UTF8.self)
                checks["noPlaintextOnDisk"] = !disk.contains("accepted-fixture") && !disk.contains("rejected-fixture")
                first.stop()
                do { let reused = try broker(stored, existing: true); request(reused, prompt: prompt) { [self] in checks["nextConnectionReusesSavedPassword"] = $0?.answer == "accepted-fixture"; reused.stop() } }
                catch { checks["reuseFailed"] = false; advance() }
            }
            let other = try broker(profile, existing: true)
            for (label, challenge) in [("key", "Enter passphrase for key 'fixture':"), ("otp", "Verification code:"), ("jump", "jump@192.0.2.45's password:")] {
                steps.append { [self] in request(other, prompt: challenge, answer: "one-shot", label: label) }
            }
            steps.append { [self] in request(other, prompt: "", hint: "oshell-session-ready") }
            steps.append { [self] in checks["otherSecretsNeverSaved"] = savedCount == 1; other.stop(); advance() }
            let external = try broker(profile, existing: true, permitsSaving: false)
            steps.append { [self] in request(external, prompt: prompt, answer: "ticket-fixture", label: "external") }
            steps.append { [self] in request(external, prompt: "", hint: "oshell-session-ready") }
            steps.append { [self] in checks["externalTicketNeverSaved"] = savedCount == 1; external.stop(); advance() }
            var temporary = profile; temporary.id = UUID(); temporary.name = "临时会话"
            let fresh = try broker(temporary, existing: false)
            steps.append { [self] in request(fresh, prompt: prompt, answer: "temporary-fixture", save: true, label: "temporary") }
            steps.append { [self] in request(fresh, prompt: "", hint: "oshell-session-ready") }
            steps.append { [self] in checks["temporarySessionSavedOnce"] = savedCount == 2 && workspace.configuration.profiles.filter { $0.id == temporary.id }.count == 1; fresh.stop(); advance() }
            let master = "login-save-master-fixture"
            steps.append { [self] in
                do {
                    var masterConfig = Configuration(profiles: [profile]); masterConfig.masterPasswordVerifier = try MasterPasswordProtection.createVerifier(master)
                    _ = workspace.saveConfiguration(masterConfig, updatingMasterProtection: true); PasswordVault.shared.unlockForTesting(master)
                } catch { checks["masterSetupFailed"] = false }
                advance()
            }
            let protected = try broker(profile, existing: true)
            steps.append { [self] in request(protected, prompt: prompt, answer: "protected-fixture", save: true, label: "master") }
            steps.append { [self] in request(protected, prompt: "", hint: "oshell-session-ready") }
            steps.append { [self] in
                checks["existingMasterUsed"] = savedCount == 3 && workspace.configuration.profiles[0].encryptedPassword?.localKeyID == nil
                checks["masterSavedPasswordDecrypts"] = (try? PasswordVault.shared.readSavedPassword(workspace.configuration.profiles[0])) == "protected-fixture"
                protected.stop(); advance()
            }
            advance()
        } catch { checks["unexpectedError"] = false; finish() }
    }
    private func finish() {
        brokers.forEach { $0.stop(); $0.onSavePassword = nil }; brokers = []; steps = []
        let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_LOGIN_SAVE_OUTPUT"] { try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        print("Login saving: \(checks.count) checks; failed: \(checks.filter { !$0.value }.keys.sorted())")
        workspace.shutdown(); Self.retained = nil; NSApp.terminate(nil)
    }
}
