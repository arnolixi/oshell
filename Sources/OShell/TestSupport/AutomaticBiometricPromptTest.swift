// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

/// No biometric system prompt or real credential access in these UI race tests.
final class TestBiometricAuthenticator: BiometricAuthenticating {
    var enabled = true
    var automaticResult: Result<String, Error>?
    var requests = [BiometricRequest]()
    var completions = [(Result<String, Error>) -> Void]()
    func beginUnlock(completion: @escaping (Result<String, Error>) -> Void) -> BiometricRequest {
        let request = BiometricRequest(); requests.append(request); completions.append(completion)
        if let automaticResult { DispatchQueue.global().async { BiometricDelivery.onMain { completion(automaticResult) } } }
        return request
    }
}

enum AutomaticBiometricPromptTest {
    static func run(_ workspace: WorkspaceController) {
        DispatchQueue.main.async { exercise(workspace) }
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func later(_ delay: TimeInterval = 0.35, _ body: @escaping () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in body() }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
        }
        func prompt(_ auth: TestBiometricAuthenticator, automatically: Bool = true) -> (PopupAlert, NSSecureTextField, NSTextField, AutomaticBiometricPrompt) {
            let alert = PopupAlert(); alert.messageText = "自动指纹解锁测试"
            alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 46, width: 330, height: 24))
            let status = NSTextField(wrappingLabelWithString: ""); status.frame = NSRect(x: 0, y: 0, width: 330, height: 40)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 76)); content.addSubview(field); content.addSubview(status)
            alert.accessoryView = content; alert.window.initialFirstResponder = field
            return (alert, field, status, AutomaticBiometricPrompt(alert: alert, field: field, status: status, automatically: automatically, authenticator: auth))
        }
        let cancelled = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        do {
            let auth = TestBiometricAuthenticator(); auth.automaticResult = .success("runloop-fixture")
            let (alert, _, _, driver) = prompt(auth)
            let watchdog = Timer(timeInterval: 2, repeats: false) { _ in alert.buttons[1].performClick(nil) }
            RunLoop.main.add(watchdog, forMode: .common); RunLoop.main.add(watchdog, forMode: .modalPanel)
            checks["backgroundReplyWorksInsideMainQueueModal"] = driver.runModal() == .alertThirdButtonReturn && driver.password == "runloop-fixture"
            watchdog.invalidate()
        }
        do {
            let auth = TestBiometricAuthenticator(), (alert, field, _, driver) = prompt(auth)
            later {
                checks["startsWithoutButtonClick"] = auth.requests.count == 1
                checks["passwordRemainsEditable"] = field.isEnabled && field.isEditable && NSApp.modalWindow === alert.window
                auth.completions.first?(.success("fixture-auto-master"))
                if auth.completions.isEmpty { alert.buttons[1].performClick(nil) }
            }
            checks["automaticSuccessCompletesPrompt"] = driver.runModal() == .alertThirdButtonReturn && driver.password == "fixture-auto-master"
        }
        do {
            let auth = TestBiometricAuthenticator(), (alert, field, _, driver) = prompt(auth)
            later(0.05) {
                field.stringValue = "manual-early"
                NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
                alert.buttons[0].performClick(nil)
            }
            checks["earlyManualEntryWins"] = driver.runModal() == .alertFirstButtonReturn && driver.password == nil && auth.requests.isEmpty
        }
        do {
            let auth = TestBiometricAuthenticator(), (alert, field, _, driver) = prompt(auth)
            later {
                field.stringValue = "manual-pending"
                NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
                checks["typingCancelsPendingRequest"] = auth.requests.first?.isCancelled == true
                auth.completions.first?(.success("late-fixture"))
                checks["lateSuccessDoesNotOverrideTyping"] = driver.password == nil && field.stringValue == "manual-pending" && NSApp.modalWindow === alert.window
                alert.buttons[0].performClick(nil)
            }
            checks["manualSubmitRemainsAvailable"] = driver.runModal() == .alertFirstButtonReturn
        }
        do {
            let auth = TestBiometricAuthenticator(), (alert, field, _, driver) = prompt(auth)
            later {
                field.stringValue = "autofill-fixture"
                auth.completions.first?(.success("late-fixture"))
                checks["autofillWithoutNotificationWins"] = driver.password == nil && field.stringValue == "autofill-fixture" && NSApp.modalWindow === alert.window
                alert.buttons[0].performClick(nil)
            }
            _ = driver.runModal()
        }
        do {
            let auth = TestBiometricAuthenticator(), (alert, _, status, driver) = prompt(auth)
            later {
                auth.completions.first?(.failure(cancelled))
                checks["cancelStaysInPasswordWindow"] = NSApp.modalWindow === alert.window && status.stringValue.contains("主密码")
                later {
                    checks["failureDoesNotAutoRepeat"] = auth.requests.count == 1
                    alert.buttons[0].performClick(nil)
                }
            }
            _ = driver.runModal()
            later { checks["manualValidationRetryDoesNotAutoRepeat"] = auth.requests.count == 1; alert.buttons[1].performClick(nil) }
            _ = driver.runModal()
        }
        do {
            let auth = TestBiometricAuthenticator(), (alert, _, _, driver) = prompt(auth)
            later { auth.completions.first?(.failure(cancelled)); alert.buttons[2].performClick(nil) }
            checks["explicitRetryRequested"] = driver.runModal() == .alertThirdButtonReturn && driver.password == nil
            later {
                checks["onlyExplicitRetryStartsAnotherRequest"] = auth.requests.count == 2
                auth.completions.last?(.success("retried-fixture"))
                if auth.completions.isEmpty { alert.buttons[1].performClick(nil) }
            }
            checks["retryCanSucceed"] = driver.runModal() == .alertThirdButtonReturn && driver.password == "retried-fixture"
        }
        do {
            let auth = TestBiometricAuthenticator(), (alert, _, _, driver) = prompt(auth)
            later { alert.buttons[1].performClick(nil) }
            _ = driver.runModal()
            checks["dismissCancelsPendingRequest"] = auth.requests.first?.isCancelled == true
            let other = PopupAlert(); other.messageText = "其他弹窗"; other.addButton(withTitle: "取消")
            later {
                auth.completions.first?(.success("late-fixture"))
                checks["lateReplyDoesNotCloseOtherDialog"] = driver.password == nil && NSApp.modalWindow === other.window
                other.buttons[0].performClick(nil)
            }
            _ = other.runModal()
        }
        do {
            let auth = TestBiometricAuthenticator(), (alert, _, _, driver) = prompt(auth, automatically: false)
            later { checks["outerStartupRetryCanSuppressAutomaticRequest"] = auth.requests.isEmpty; alert.buttons[1].performClick(nil) }
            _ = driver.runModal()
        }
        do {
            let auth = TestBiometricAuthenticator(), (alert, _, status, driver) = prompt(auth)
            later { alert.buttons[0].performClick(nil) }
            _ = driver.runModal()
            checks["emptySubmitCancelsFingerprint"] = auth.requests.first?.isCancelled == true
            later {
                checks["emptySubmitDoesNotShowStaleWaitingState"] = auth.requests.count == 1 && status.stringValue.contains("重试") && !status.stringValue.contains("请验证")
                alert.buttons[1].performClick(nil)
            }
            _ = driver.runModal()
        }
        do {
            let auth = TestBiometricAuthenticator(), (alert, _, status, driver) = prompt(auth)
            later {
                let nested = PopupAlert(); nested.messageText = "嵌套确认"; nested.addButton(withTitle: "取消")
                later(0.1) {
                    auth.completions.first?(.success("nested-late-fixture"))
                    checks["replyDoesNotDismissNestedDialog"] = NSApp.modalWindow === nested.window && driver.password == nil
                    checks["nestedDialogDoesNotLeaveFingerprintBusy"] = alert.buttons[2].isEnabled && status.stringValue.contains("重试")
                    nested.buttons[0].performClick(nil)
                }
                _ = nested.runModal()
                alert.buttons[1].performClick(nil)
            }
            _ = driver.runModal()
        }
        for (title, creating, enabled) in [("导出文件密码", false, true), ("设置主密码", true, true), ("解锁 OShell 加密数据", false, false)] {
            let auth = TestBiometricAuthenticator(); auth.enabled = enabled
            later { checks[title + "HasNoUnwantedAutomaticRequest"] = auth.requests.isEmpty; if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
            _ = PasswordVault.promptMaster(title: title, creating: creating, allowBiometrics: true, authenticator: auth)
        }
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let output = ProcessInfo.processInfo.environment["OSHELL_AUTOMATIC_BIOMETRIC_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output)) }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
