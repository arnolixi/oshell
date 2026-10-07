// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

final class AuthBroker {
    private let directory: URL
    private let endpoint: URL
    private let token = UUID().uuidString + UUID().uuidString
    private let queue = DispatchQueue(label: "OShell.auth.accept", qos: .userInitiated)
    private var source: DispatchSourceRead?
    private var stopped = false
    private var policy: SavedPasswordPolicy?
    private var proxyAttempted = false
    private let profile: SessionProfile
    var onAuthenticated: (() -> Void)?
    var manualPrompt: ((AuthRequest, @escaping (AuthResponse) -> Void) -> Void)?
    init(profile: SessionProfile, oneTimePassword: String? = nil) throws {
        self.profile = profile
        if let oneTimePassword { policy = SavedPasswordPolicy(identity: try SSHIdentity.resolve(profile), password: oneTimePassword) }
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oa-" + String(UUID().uuidString.prefix(8)))
        endpoint = directory.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ModelError.invalid("无法创建密码认证通道。") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = try AuthIPC.address(endpoint.path)
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw ModelError.invalid("无法绑定密码认证通道。") }
        _ = chmod(endpoint.path, 0o600)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC); _ = fcntl(client, F_SETFL, 0)
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); continue }
                DispatchQueue.global(qos: .userInitiated).async {
                    var timeout = timeval(tv_sec: 5, tv_usec: 0)
                    _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    do {
                        let request = try AuthIPC.read(AuthRequest.self, fd: client)
                        DispatchQueue.main.async {
                            guard let self, !self.stopped, request.token == self.token else { close(client); return }
                            self.respond(request) { [weak self] response in
                                let allowedResponse = self?.stopped == false ? response : AuthResponse(success: false)
                                DispatchQueue.global(qos: .userInitiated).async {
                                    try? AuthIPC.write(allowedResponse, fd: client)
                                    close(client)
                                }
                            }
                        }
                    } catch { close(client) }
                }
            }
        }
        reader.setCancelHandler { close(fd) }; reader.resume(); source = reader
    }
    var environment: [String: String] {
        var values = ["SSH_ASKPASS": ZmodemTransfer.helperDirectory.appendingPathComponent("OShellAskpass").path,
                      "SSH_ASKPASS_REQUIRE": "force", "OSHELL_AUTH_SOCKET": endpoint.path, "OSHELL_AUTH_TOKEN": token]
        if OpenSSHCapabilities.current.needsLegacyAskpass {
            values.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
            values["DISPLAY"] = ProcessInfo.processInfo.environment["DISPLAY"] ?? "oshell:0"
        }
        return values
    }
    private func respond(_ request: AuthRequest, completion: @escaping (AuthResponse) -> Void) {
        if request.hint == "oshell-session-ready" { onAuthenticated?(); completion(AuthResponse(success: true)); return }
        if request.hint == "oshell-proxy" {
            guard profile.proxy.supportsPassword, !profile.proxy.username.isEmpty, !proxyAttempted else { completion(AuthResponse(success: false)); return }
            proxyAttempted = true
            if profile.proxy.encryptedPassword != nil {
                PasswordVault.shared.decrypt(profile.proxy.credentialProfile, resolve: false) { result in
                    switch result {
                    case .success(let value): completion(AuthResponse(success: true, answer: value.0))
                    case .failure(let error): Dialogs.message(error.localizedDescription); completion(AuthResponse(success: false))
                    }
                }
            } else if let manualPrompt { manualPrompt(request, completion) }
            else {
                let alert = PopupAlert(); alert.messageText = "代理身份验证"; alert.informativeText = "\(profile.proxy.username)@\(profile.proxy.host):\(profile.proxy.port)"
                alert.addButton(withTitle: "连接"); alert.addButton(withTitle: "取消")
                let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 26))
                alert.accessoryView = password; alert.window.initialFirstResponder = password
                let accepted = alert.runModal() == .alertFirstButtonReturn
                completion(AuthResponse(success: accepted, answer: accepted ? password.stringValue : "")); password.stringValue = ""
            }
            return
        }
        if request.hint == "none" { completion(AuthResponse(success: true)); return }
        if var policy, let answer = policy.reply(prompt: request.prompt, hint: request.hint) {
            self.policy = policy; completion(AuthResponse(success: true, answer: answer)); return
        }
        if policy == nil, let envelope = profile.encryptedPassword, request.hint != "confirm" {
            var check = SavedPasswordPolicy(identity: envelope.identity, password: "probe")
            if check.reply(prompt: request.prompt, hint: request.hint) != nil {
                PasswordVault.shared.decrypt(profile) { [weak self] result in
                    guard let self, !self.stopped else { completion(AuthResponse(success: false)); return }
                    switch result {
                    case .success(let value):
                        var policy = SavedPasswordPolicy(identity: value.1, password: value.0)
                        let answer = policy.reply(prompt: request.prompt, hint: request.hint)
                        self.policy = policy; completion(AuthResponse(success: answer != nil, answer: answer ?? ""))
                    case .failure(let error): Dialogs.message(error.localizedDescription); completion(AuthResponse(success: false))
                    }
                }
                return
            }
        }
        if let manualPrompt { manualPrompt(request, completion); return }
        let alert = PopupAlert(); alert.messageText = "SSH 身份验证"; alert.informativeText = request.prompt
        if request.hint == "confirm" || request.prompt.contains("(yes/no") {
            alert.addButton(withTitle: "确认连接"); alert.addButton(withTitle: "取消")
            completion(AuthResponse(success: true, answer: alert.runModal() == .alertFirstButtonReturn ? "yes" : "no")); return
        }
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let field = NSSecureTextField(); field.frame = NSRect(x: 0, y: 0, width: 330, height: 26)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        let accepted = alert.runModal() == .alertFirstButtonReturn
        completion(AuthResponse(success: accepted, answer: accepted ? field.stringValue : "")); field.stringValue = ""
    }
    func stop() { stopped = true; policy = nil; source?.cancel(); source = nil; try? FileManager.default.removeItem(at: directory) }
    deinit { source?.cancel(); try? FileManager.default.removeItem(at: directory) }
}
