// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin
import OShellCore

/// One authenticated SSH transport, scoped to one connection (never host-wide).
/// Holds no password. OpenSSH owns transport authentication and session channels.
final class SSHConnectionGroup {
    private static let cleanup = DispatchGroup()
    let directory: URL
    let isExternal: Bool
    var controlPath: String { directory.appendingPathComponent("s").path }
    private let profileID: UUID, host: String, user: String, port: Int
    private let lock = NSLock()
    private var holders = Set<UUID>()
    private var authenticated = false, stopped = false

    init(profile: SessionProfile, external: Bool = false) throws {
        isExternal = external
        profileID = profile.id; host = profile.host; user = profile.username; port = profile.port
        var template = Array("/tmp/oshell-mux-\(geteuid())-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw ModelError.invalid("无法创建 SSH 连接复用通道。") }
        directory = URL(fileURLWithPath: String(cString: template))
    }
    func attach(_ id: UUID) { lock.lock(); holders.insert(id); lock.unlock() }
    func authenticatedConnectionReady() { lock.lock(); authenticated = true; lock.unlock() }
    var isAuthenticated: Bool { lock.lock(); defer { lock.unlock() }; return authenticated }
    var isAvailable: Bool {
        lock.lock(); let allowed = authenticated && !stopped; lock.unlock()
        var info = stat()
        return allowed && lstat(controlPath, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == geteuid() && (info.st_mode & 0o077) == 0
    }
    func arguments(for profile: SessionProfile, clone: Bool) throws -> [String] {
        guard profile.id == profileID, profile.host == host, profile.username == user, profile.port == port else { throw ModelError.invalid("连接复用目标与原会话不一致。") }
        lock.lock(); let stopped = self.stopped; lock.unlock()
        guard !stopped else { throw ModelError.invalid("SSH 连接复用已结束，请重新建立会话。") }
        if clone {
            guard isAvailable else { throw ModelError.invalid("已认证的 SSH 连接不可用，请重新建立会话。") }
            // OpenSSH normally falls back to a fresh connection when multiplexing
            // fails. An inert ProxyCommand and BatchMode make this fail closed.
            return ["-F", "/dev/null", "-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)",
                    "-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes",
                    "-o", "ConnectionAttempts=1", "-o", "ConnectTimeout=3"]
        }
        return ["-o", "ControlMaster=yes", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=60"]
    }
    func detach(_ id: UUID) {
        lock.lock(); holders.remove(id); let empty = holders.isEmpty; lock.unlock()
        if empty { close() }
    }
    private func close() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; lock.unlock()
        let directory = directory, controlPath = controlPath, host = host
        Self.cleanup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { try? FileManager.default.removeItem(at: directory); Self.cleanup.leave() }
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            task.arguments = ["-F", "/dev/null", "-S", controlPath, "-O", "exit", "--", host]
            task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                let deadline = Date().addingTimeInterval(2)
                while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                task.waitUntilExit()
            } catch { /* The master may already have expired; remove our private directory. */ }
        }
    }
    static func finishCleanup() { _ = cleanup.wait(timeout: .now() + 3) }
    deinit { close() }
}
