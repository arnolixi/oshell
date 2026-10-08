// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

private struct CredentialTaskCancelled: Error {}

final class CredentialCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw CredentialTaskCancelled() } }
}

enum CredentialTask {
    /// Keep the UI responsive during PBKDF2 and never commit after Cancel/Esc.
    static func run<T>(title: String, message: String = "正在处理加密凭据。完成后一次性保存；取消不会修改配置。", work: @escaping (CredentialCancellation) throws -> T) -> Result<T, Error>? {
        let alert = PopupAlert(); alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "取消")
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 320, height: 20))
        spinner.style = .bar; spinner.isIndeterminate = true; spinner.startAnimation(nil); alert.accessoryView = spinner
        let token = CredentialCancellation()
        var outcome: Result<T, Error>?, finished = false
        func deliver(_ result: Result<T, Error>) {
            guard !finished else { return }
            // An authentication prompt may temporarily be nested over this alert.
            guard NSApp.modalWindow === alert.window else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { deliver(result) }; return
            }
            outcome = result; NSApp.stopModal(withCode: .OK)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(token) }
            DispatchQueue.main.async { deliver(result) }
        }
        let response = alert.runModal(); finished = true; token.cancel()
        return response == .OK ? outcome : nil
    }
}
