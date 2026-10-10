// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// Start biometrics once after the password window appears, without a nested
/// progress modal. Manual typing, submission and dismissal cancel the request.
final class AutomaticBiometricPrompt {
    private let alert: PopupAlert, field: NSSecureTextField, status: NSTextField
    private let authenticator: BiometricAuthenticating
    private let retry: NSButton
    private var attempted: Bool, retryRequested = false, running = false
    private var generation = 0
    private var timer: Timer?, request: BiometricRequest?, observer: NSObjectProtocol?
    private(set) var password: String?
    init(alert: PopupAlert, field: NSSecureTextField, status: NSTextField,
         automatically: Bool = true, authenticator: BiometricAuthenticating = BiometricUnlock.shared) {
        self.alert = alert; self.field = field; self.status = status; self.authenticator = authenticator
        attempted = !automatically
        retry = alert.addButton(withTitle: "重试 Touch ID"); retry.identifier = .init("master.touchID")
    }
    private func cancelRequest() {
        generation += 1; timer?.invalidate(); timer = nil
        request?.cancel(); request = nil; retry.isEnabled = true
    }
    private func start() {
        guard running, NSApp.modalWindow === alert.window else { return }
        cancelRequest()
        let token = generation, textAtStart = field.stringValue
        status.stringValue = "请验证指纹，也可选择输入主密码。"; status.textColor = .secondaryLabelColor
        retry.isEnabled = false
        request = authenticator.beginUnlock { [weak self] result in
            guard let self, self.running, self.generation == token else { return }
            guard NSApp.modalWindow === self.alert.window else {
                self.cancelRequest()
                self.status.stringValue = "可输入主密码，或点击重试 Touch ID。"; self.status.textColor = .secondaryLabelColor
                return
            }
            // Covers autofill and input methods in addition to ordinary edits.
            guard self.field.stringValue == textAtStart,
                  (self.field.currentEditor() as? NSTextView)?.hasMarkedText() != true else {
                self.cancelRequest(); self.status.stringValue = "请继续输入主密码。"; self.status.textColor = .secondaryLabelColor; return
            }
            self.generation += 1; self.request = nil; self.retry.isEnabled = true
            switch result {
            case .success(let password):
                self.password = password
                NSApp.stopModal(withCode: .alertThirdButtonReturn)
            case .failure(let error):
                self.status.stringValue = BiometricUnlock.message(for: error); self.status.textColor = .secondaryLabelColor
                self.alert.window.makeFirstResponder(self.field)
            }
        }
    }
    func runModal() -> NSApplication.ModalResponse {
        running = true; password = nil
        observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            self.cancelRequest(); self.status.stringValue = "请继续输入主密码。"; self.status.textColor = .secondaryLabelColor
        }
        if !attempted || retryRequested {
            let explicitRetry = retryRequested
            attempted = true; retryRequested = false
            let pending = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.timer = nil
                if explicitRetry || self.field.stringValue.isEmpty { self.start() }
            }
            timer = pending
            RunLoop.main.add(pending, forMode: .common); RunLoop.main.add(pending, forMode: .modalPanel)
        }
        let response = alert.runModal()
        running = false; cancelRequest()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if response == .alertFirstButtonReturn && password == nil {
            status.stringValue = "请输入主密码，或点击重试 Touch ID。"; status.textColor = .secondaryLabelColor
        }
        if response == .alertThirdButtonReturn && password == nil { retryRequested = true }
        return response
    }
    deinit { cancelRequest(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}
