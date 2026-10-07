// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import CommonCrypto
import Darwin

public enum LaunchEndpoint {
    public static var configurationDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OShell")
    }
    public static func directory(for configuration: URL) throws -> URL {
        let digest = PlatformDigest.sha256(Data(configuration.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let directory = URL(fileURLWithPath: "/tmp/oshell-launch-\(geteuid())-\(digest)")
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw ModelError.invalid("无法创建本机启动通道。") }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else { throw ModelError.invalid("本机启动通道目录权限无效。") }
        return directory
    }
    public static func lock(_ name: String, directory: URL, nonblocking: Bool = false) throws -> Int32 {
        let fd = Darwin.open(directory.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ModelError.invalid("无法打开启动通道锁。") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), (info.st_mode & 0o077) == 0,
              flock(fd, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else { close(fd); throw ModelError.invalid("同一配置的 OShell 启动服务已运行，或锁文件不可用。") }
        return fd
    }
    public static func connect(directory: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ModelError.invalid("无法创建启动连接。") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // A previously opened connection may be waiting for host-key confirmation.
        var receiveTimeout = timeval(tv_sec: 300, tv_usec: 0), sendTimeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        var address = try AuthIPC.address(directory.appendingPathComponent("s").path)
        let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        var uid: uid_t = 0, gid: gid_t = 0
        guard result == 0, getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { close(fd); throw ModelError.invalid("OShell 启动服务尚未就绪。") }
        return fd
    }
}
