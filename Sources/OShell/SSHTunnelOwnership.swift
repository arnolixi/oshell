// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation
import Darwin
import OShellCore

/// Process-wide ownership by saved profile identity, including pending logins.
/// The claim follows the SSH transport, not the tab or an individual channel.
final class SSHTunnelOwnership {
    static let shared = SSHTunnelOwnership()
    private enum Phase { case starting, established, closing }
    private struct Claim { let owner: UUID, path: String; var phase: Phase }
    private let lock = NSLock()
    private var claims = [UUID: Claim]()
    func acquire(profile: UUID, owner: UUID, controlPath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let current = claims[profile] {
            if current.owner == owner { return current.phase != .closing }
            // ControlPersist can expire while the ended tab remains open.
            // A stale socket file alone does not mean a live transport.
            if current.phase == .established && !Self.transportIsAlive(current.path) { claims.removeValue(forKey: profile) }
            else { return false }
        }
        claims[profile] = Claim(owner: owner, path: controlPath, phase: .starting)
        return true
    }
    func established(profile: UUID, owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard claims[profile]?.owner == owner, claims[profile]?.phase != .closing else { return }
        claims[profile]?.phase = .established
    }
    func processEnded(profile: UUID, owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let current = claims[profile], current.owner == owner, current.phase != .closing else { return }
        if Self.transportIsAlive(current.path) { claims[profile]?.phase = .established }
        else { claims.removeValue(forKey: profile) }
    }
    func closing(profile: UUID, owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        if claims[profile]?.owner == owner { claims[profile]?.phase = .closing }
    }
    /// False keeps the control socket and claim intact if shutdown did not work.
    func finishedClosing(profile: UUID, owner: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = claims[profile], current.owner == owner else { return true }
        if Self.transportIsAlive(current.path) { claims[profile]?.phase = .established; return false }
        claims.removeValue(forKey: profile); return true
    }
    private static func transportIsAlive(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 { return errno != ENOENT }
        // Uncertain errors remain reserved; never turn them into duplicate binds.
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(),
              var address = try? AuthIPC.address(path) else { return true }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return true }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0 || (errno != ECONNREFUSED && errno != ENOENT)
    }
}
