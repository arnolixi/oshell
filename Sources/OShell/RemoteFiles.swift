// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

struct RemoteFileEntry {
    let name: String
    let size: UInt64
    let modified: Date?
    let directory: Bool
    let symbolicLink: Bool
    let unknownType: Bool
    init(name: String, size: UInt64, modified: Date?, directory: Bool, symbolicLink: Bool, unknownType: Bool = false) {
        self.name = name; self.size = size; self.modified = modified; self.directory = directory; self.symbolicLink = symbolicLink; self.unknownType = unknownType
    }
}
protocol RemoteFileBackend: AnyObject {
    var description: String { get }
    func connect() throws
    func canonicalPath(_ path: String) throws -> String
    func list(_ path: String) throws -> [RemoteFileEntry]
    func upload(_ local: URL, to remote: String, progress: @escaping (UInt64, UInt64) -> Void) throws
    func download(_ remote: String, to local: URL, progress: @escaping (UInt64, UInt64) -> Void) throws
    func mkdir(_ path: String) throws
    func rename(_ source: String, to destination: String) throws
    func remove(_ path: String, directory: Bool) throws
    func cancel()
}

/// A child process with bounded stderr and cancellable, timeout-aware pipe I/O.
final class FileProcess {
    let task = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var errorData = Data()
    private var cancelled = false
    init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        let legacyClient = OpenSSHCapabilities.current.needsLegacyAskpass && ["/usr/bin/ssh", "/usr/bin/scp"].contains(executable)
        task.executableURL = legacyClient ? ZmodemTransfer.helperDirectory.appendingPathComponent("OShellSSH") : URL(fileURLWithPath: executable)
        task.arguments = (legacyClient && executable == "/usr/bin/scp" ? ["--scp"] : []) + arguments
        task.environment = environment; task.standardInput = input; task.standardOutput = output; task.standardError = errors
    }
    func start() throws {
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }; self.lock.lock(); self.errorData.append(data.prefix(max(0, 16384 - self.errorData.count))); self.lock.unlock()
        }
        lock.lock()
        guard !cancelled else { lock.unlock(); throw ModelError.invalid("操作已取消。") }
        do { try task.run(); lock.unlock() } catch { lock.unlock(); throw error }
        input.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile(); errors.fileHandleForWriting.closeFile()
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
    }
    var errorText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func checkCancelled() throws { lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw ModelError.invalid("操作已取消。") } }
    func write(_ data: Data, timeout: TimeInterval = 30) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout, fd = input.fileHandleForWriting.fileDescriptor
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                try checkCancelled()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ModelError.invalid("文件传输写入超时。") }
                var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pollFD, 1, 100)
                if ready <= 0 { continue }
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw ModelError.invalid("文件连接已关闭。\n" + errorText) }; offset += count
            }
        }
    }
    func read(_ count: Int, timeout: TimeInterval = 60) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout, fd = output.fileHandleForReading.fileDescriptor
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            try checkCancelled()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ModelError.invalid("文件服务器响应超时。") }
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pollFD, 1, 100) <= 0 { continue }
            var bytes = [UInt8](repeating: 0, count: min(32768, count - result.count))
            let size = Darwin.read(fd, &bytes, bytes.count)
            if size < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard size > 0 else { throw ModelError.invalid("文件连接已关闭。\n" + errorText) }; result.append(contentsOf: bytes.prefix(size))
        }
        return result
    }
    func outputToEnd(limit: Int = 4 * 1024 * 1024, sink: FileHandle? = nil, progress: ((UInt64) -> Void)? = nil) throws -> Data {
        let fd = output.fileHandleForReading.fileDescriptor
        var result = Data(), total: UInt64 = 0
        while true {
            try checkCancelled()
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) <= 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 32768)
            let size = Darwin.read(fd, &bytes, bytes.count)
            if size < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            if size == 0 { break }
            guard size > 0, sink != nil || result.count + size <= limit else { cancel(); throw ModelError.invalid("目录输出过大或连接读取失败。") }
            if let sink { try sink.oshellWrite(contentsOf: Data(bytes.prefix(size))) } else { result.append(contentsOf: bytes.prefix(size)) }
            total += UInt64(size); progress?(total)
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw ModelError.invalid(errorText.isEmpty ? "文件操作失败（\(task.terminationStatus)）。" : errorText) }
        return result
    }
    func closeInput() { try? input.fileHandleForWriting.oshellClose() }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if task.isRunning {
            task.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [task] in if task.isRunning { kill(task.processIdentifier, SIGKILL) } }
        }
    }
    deinit { errors.fileHandleForReading.readabilityHandler = nil; if task.isRunning { task.terminate() }; try? input.fileHandleForWriting.oshellClose(); try? output.fileHandleForReading.oshellClose(); try? errors.fileHandleForReading.oshellClose() }
}

enum FileSSH {
    static func arguments(_ profile: SessionProfile, knownHosts: URL) throws -> [String] {
        var copy = profile; copy.tunnels = []
        let args = try copy.sshArguments(knownHostsFile: knownHosts, proxyHelper: ZmodemTransfer.helperDirectory.appendingPathComponent("OShellProxy"))
        return Array(args.dropLast(2)).filter { $0 != "-tt" } + ["-o", "ClearAllForwardings=yes", "-o", "RemoteCommand=none"]
    }
    static func environment(_ broker: AuthBroker?) -> [String: String] {
        var environment = SSHEnvironment.remoteClient(ProcessInfo.processInfo.environment)
        if let broker { environment.merge(broker.environment) { _, new in new } }
        else { for key in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "OSHELL_AUTH_SOCKET", "OSHELL_AUTH_TOKEN"] { environment.removeValue(forKey: key) } }
        return environment
    }
}
struct SFTPStatus: LocalizedError {
    let code: UInt32; let message: String
    var errorDescription: String? { "SFTP（\(code)）：\(message)" }
}
struct SFTPPacket {
    var data = Data(), offset = 0
    mutating func u32(_ value: UInt32) { data.append(contentsOf: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    mutating func u64(_ value: UInt64) { u32(UInt32(value >> 32)); u32(UInt32(value & 0xffffffff)) }
    mutating func bytes(_ value: Data) { u32(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) { bytes(Data(value.utf8)) }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw ModelError.invalid("SFTP 响应长度无效。") }
        defer { offset += count }; return Data(data[offset..<offset + count])
    }
    mutating func read32() throws -> UInt32 { try take(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func read64() throws -> UInt64 { let high = try read32(), low = try read32(); return (UInt64(high) << 32) | UInt64(low) }
    mutating func readBytes() throws -> Data { let count = try read32(); guard count <= 4 * 1024 * 1024 else { throw ModelError.invalid("SFTP 字段过大。") }; return try take(Int(count)) }
    mutating func readString() throws -> String { guard let text = String(data: try readBytes(), encoding: .utf8) else { throw ModelError.invalid("服务器文件名不是 UTF-8，无法安全处理。"); }; return text }
    mutating func attributes(name: String) throws -> RemoteFileEntry {
        let flags = try read32(); var size: UInt64 = 0, mode: UInt32 = 0; var date: Date?
        if flags & 1 != 0 { size = try read64() }
        if flags & 2 != 0 { _ = try take(8) }
        if flags & 4 != 0 { mode = try read32() }
        if flags & 8 != 0 { _ = try read32(); date = Date(timeIntervalSince1970: Double(try read32())) }
        if flags & 0x80000000 != 0 {
            let count = try read32(); guard count <= 64 else { throw ModelError.invalid("SFTP 扩展字段过多。") }
            for _ in 0..<count { _ = try readBytes(); _ = try readBytes() }
        }
        return RemoteFileEntry(name: name, size: size, modified: date, directory: mode & 0xf000 == 0x4000, symbolicLink: mode & 0xf000 == 0xa000)
    }
}
final class SFTPBackend: RemoteFileBackend {
    let description: String
    private let process: FileProcess
    private let broker: AuthBroker?
    private let lease: SSHConnectionLease?
    private var requestID: UInt32 = 0
    private var connected = false
    init(profile: SessionProfile, knownHosts: URL, oneTimePassword: String? = nil, connectionGroup: SSHConnectionGroup? = nil) throws {
        description = "SFTP · \(profile.name) · \(profile.host)"
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lease = try connectionGroup.map { try SSHConnectionLease(group: $0, profile: profile) }
        broker = connectionGroup == nil ? try AuthBroker(profile: profile, oneTimePassword: oneTimePassword) : nil
        let shared = try connectionGroup?.arguments(for: profile, clone: true) ?? []
        let args = shared + (try FileSSH.arguments(profile, knownHosts: knownHosts)) + ["-T", "-s", "--", profile.host, "sftp"]
        process = FileProcess(executable: "/usr/bin/ssh", arguments: args, environment: FileSSH.environment(broker))
    }
    func connect() throws {
        guard !connected else { return }
        do {
            try process.start()
            var packet = SFTPPacket(); packet.data.append(1); packet.u32(3); try send(packet)
            var response = try receive(timeout: 300)
            guard try response.take(1).first == 2, try response.read32() == 3 else { throw ModelError.invalid("服务器不支持 SFTP v3。") }
            connected = true
        } catch {
            process.cancel()
            if lease != nil { throw ModelError.invalid("无法通过现有 SSH 连接打开 SFTP。请确认服务器允许 SFTP 子系统，且 SSH 连接仍有效。\n" + error.localizedDescription) }
            throw error
        }
    }
    private func send(_ packet: SFTPPacket) throws { var framed = SFTPPacket(); framed.bytes(packet.data); try process.write(framed.data) }
    private func receive(timeout: TimeInterval = 60) throws -> SFTPPacket {
        var size = SFTPPacket(data: try process.read(4, timeout: timeout)); let count = try size.read32()
        guard count > 0, count <= 4 * 1024 * 1024 else { throw ModelError.invalid("SFTP 数据包长度无效。") }
        return SFTPPacket(data: try process.read(Int(count), timeout: timeout))
    }
    private func request(_ type: UInt8, build: (inout SFTPPacket) -> Void) throws -> (UInt8, SFTPPacket) {
        requestID &+= 1; var packet = SFTPPacket(); packet.data.append(type); packet.u32(requestID); build(&packet); try send(packet)
        var response = try receive(); let kind = try response.take(1)[0], id = try response.read32()
        guard id == requestID else { throw ModelError.invalid("SFTP 请求编号不匹配。") }
        if kind == 101 {
            let code = try response.read32(), message = try response.readString()
            if code != 0 { throw SFTPStatus(code: code, message: message) }
        }
        return (kind, response)
    }
    private func handle(_ type: UInt8, path: String, flags: UInt32? = nil) throws -> Data {
        try RemotePath.validate(path)
        let response = try request(type) { p in p.string(path); if let flags { p.u32(flags); p.u32(0) } }
        guard response.0 == 102 else { throw ModelError.invalid("SFTP 未返回文件句柄。") }; var packet = response.1; return try packet.readBytes()
    }
    private func status(_ type: UInt8, build: (inout SFTPPacket) -> Void) throws {
        guard try request(type, build: build).0 == 101 else { throw ModelError.invalid("SFTP 未返回操作状态。"); }
    }
    private func close(_ handle: Data) throws { try status(4) { $0.bytes(handle) } }
    func canonicalPath(_ path: String) throws -> String {
        try RemotePath.validate(path)
        var response = try request(16) { $0.string(path) }
        guard response.0 == 104, try response.1.read32() == 1 else { throw ModelError.invalid("无法解析远程目录。") }
        return try response.1.readString()
    }
    func stat(_ path: String) throws -> RemoteFileEntry {
        try RemotePath.validate(path); var response = try request(17) { $0.string(path) }
        guard response.0 == 105 else { throw ModelError.invalid("SFTP 属性响应无效。") }; return try response.1.attributes(name: (path as NSString).lastPathComponent)
    }
    func list(_ path: String) throws -> [RemoteFileEntry] {
        let handle = try handle(11, path: path); defer { try? close(handle) }; var entries = [RemoteFileEntry]()
        while true {
            do {
                var response = try request(12) { $0.bytes(handle) }
                guard response.0 == 104 else { throw ModelError.invalid("SFTP 目录响应无效。") }
                let count = try response.1.read32(); guard count <= 20000, entries.count + Int(count) <= 100000 else { throw ModelError.invalid("目录项目过多，请进入子目录操作。") }
                guard count > 0 else { break }
                for _ in 0..<count {
                    let name = try response.1.readString(); _ = try response.1.readString(); let entry = try response.1.attributes(name: name)
                    if RemotePath.safeName(name) { entries.append(entry) }
                }
            } catch let error as SFTPStatus where error.code == 1 { break }
        }
        return entries
    }
    func mkdir(_ path: String) throws { try RemotePath.validate(path); try status(14) { $0.string(path); $0.u32(0) } }
    func rename(_ source: String, to destination: String) throws { try RemotePath.validate(source); try RemotePath.validate(destination); try status(18) { $0.string(source); $0.string(destination) } }
    func remove(_ path: String, directory: Bool) throws { try RemotePath.validate(path); try status(directory ? 15 : 13) { $0.string(path) } }
    func upload(_ local: URL, to remote: String, progress: @escaping (UInt64, UInt64) -> Void) throws {
        try upload(local, to: remote, depth: 0, progress: progress)
    }
    private func upload(_ local: URL, to remote: String, depth: Int, progress: @escaping (UInt64, UInt64) -> Void) throws {
        guard depth <= 32, RemotePath.safeName(local.lastPathComponent) else { throw ModelError.invalid("目录嵌套过深或文件名无效。") }
        let attributes = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isSymbolicLink != true else { throw ModelError.invalid("不自动跟随本地符号链接：\(local.lastPathComponent)") }
        if attributes.isDirectory == true {
            try mkdir(remote)
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) { try upload(child, to: RemotePath.join(remote, child.lastPathComponent), depth: depth + 1, progress: progress) }
            return
        }
        // EXCL protects existing remote files, including races after listing.
        let handle = try handle(3, path: remote, flags: 2 | 8 | 32); var closed = false; defer { if !closed { try? close(handle) } }
        let file = try FileHandle(forReadingFrom: local); defer { try? file.oshellClose() }
        var offset: UInt64 = 0
        while let bytes = try file.oshellRead(upToCount: 32768), !bytes.isEmpty {
            try status(6) { $0.bytes(handle); $0.u64(offset); $0.bytes(bytes) }
            offset += UInt64(bytes.count); progress(offset, UInt64(attributes.fileSize ?? 0))
        }
        try close(handle); closed = true
    }
    func download(_ remote: String, to local: URL, progress: @escaping (UInt64, UInt64) -> Void) throws { try download(remote, to: local, depth: 0, progress: progress) }
    private func download(_ remote: String, to local: URL, depth: Int, progress: @escaping (UInt64, UInt64) -> Void) throws {
        guard depth <= 32 else { throw ModelError.invalid("目录嵌套过深。") }
        let info = try stat(remote)
        if info.directory {
            guard !FileManager.default.fileExists(atPath: local.path) else { throw ModelError.invalid("本地目录已存在。") }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            for child in try list(remote) where !child.symbolicLink { try download(RemotePath.join(remote, child.name), to: local.appendingPathComponent(child.name), depth: depth + 1, progress: progress) }
            return
        }
        let handle = try handle(3, path: remote, flags: 1); var closed = false; defer { if !closed { try? close(handle) } }
        let fd = Darwin.open(local.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ModelError.invalid("无法创建本地文件或文件已存在：\(local.lastPathComponent)") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); var complete = false
        defer { try? file.oshellClose(); if !complete { try? FileManager.default.removeItem(at: local) } }
        var offset: UInt64 = 0
        while true {
            do {
                var response = try request(5) { $0.bytes(handle); $0.u64(offset); $0.u32(32768) }
                guard response.0 == 103 else { throw ModelError.invalid("SFTP 文件数据无效。") }
                let bytes = try response.1.readBytes(); guard !bytes.isEmpty else { throw ModelError.invalid("SFTP 返回空数据块。") }
                try file.oshellWrite(contentsOf: bytes); offset += UInt64(bytes.count); progress(offset, info.size)
            } catch let error as SFTPStatus where error.code == 1 { break }
        }
        try close(handle); closed = true
        try file.oshellClose(); complete = true
    }
    func cancel() { process.cancel(); lease?.release(); DispatchQueue.main.async { [broker] in broker?.stop() } }
    deinit { process.cancel(); lease?.release(); let broker = broker; DispatchQueue.main.async { broker?.stop() } }
}
