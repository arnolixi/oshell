// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

final class FTPBackend: RemoteFileBackend {
    let description: String
    private let profile: FTPProfile
    private let password: String
    private let lock = NSLock()
    private var active: FileProcess?
    private var cancelled = false
    init(profile: FTPProfile, password: String) { self.profile = profile; self.password = password; description = "FTP · \(profile.name) · \(profile.host)" }
    func connect() throws { try profile.validate(); _ = try list(profile.initialDirectory) }
    func canonicalPath(_ path: String) throws -> String {
        try RemotePath.validate(path)
        var parts = [String]()
        for part in path.split(separator: "/") { if part == ".." { if !parts.isEmpty { parts.removeLast() } } else if part != "." { parts.append(String(part)) } }
        return "/" + parts.joined(separator: "/")
    }
    private func curl(_ path: String, directory: Bool, arguments: [String] = [], sink: FileHandle? = nil, progress: ((UInt64) -> Void)? = nil) throws -> Data {
        try RemotePath.validate(path)
        guard password.utf8.count <= 4096, !password.contains("\0"), !password.contains("\r"), !password.contains("\n") else { throw ModelError.invalid("FTP 密码过长或含有协议不支持的控制字符。"); }
        var components = URLComponents(); components.scheme = "ftp"; components.host = profile.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")); components.port = profile.port
        var remote = try canonicalPath(path)
        if directory && !remote.hasSuffix("/") { remote += "/" }; components.path = remote
        guard let url = components.url else { throw ModelError.invalid("FTP 路径无效。") }
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\"" }
        let config = "url = \(quote(url.absoluteString))\nuser = \(quote(profile.username + ":" + password))\n"
        let task = FileProcess(executable: "/usr/bin/curl", arguments: ["--disable", "--config", "-", "--silent", "--show-error", "--fail", "--globoff", "--proto", "=ftp", "--noproxy", "*", "--connect-timeout", "15", "--speed-limit", "1", "--speed-time", "60"] + arguments)
        lock.lock(); if cancelled { lock.unlock(); throw ModelError.invalid("操作已取消，请重新连接。"); }; active = task; lock.unlock()
        defer { lock.lock(); active = nil; lock.unlock() }
        try task.start(); try task.write(Data(config.utf8)); task.closeInput()
        return try task.outputToEnd(sink: sink, progress: progress)
    }
    func list(_ path: String) throws -> [RemoteFileEntry] {
        do {
            let data = try curl(path, directory: true, arguments: ["--request", "MLSD"])
            return try Self.parseMLSD(data)
        } catch {
            // Older FTP servers may only support NLST. Preserve filenames and
            // allow navigating an item to discover whether it is a directory.
            do { return try Self.parseLIST(curl(path, directory: true)) } catch { }
            let data = try curl(path, directory: true, arguments: ["--list-only"])
            guard let text = String(data: data, encoding: .utf8) else { throw ModelError.invalid("FTP 文件名不是 UTF-8。") }
            return text.components(separatedBy: .newlines).filter(RemotePath.safeName).map { RemoteFileEntry(name: $0, size: 0, modified: nil, directory: false, symbolicLink: false, unknownType: true) }
        }
    }
    static func parseMLSD(_ data: Data) throws -> [RemoteFileEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw ModelError.invalid("FTP 文件名不是 UTF-8。") }
        var entries = [RemoteFileEntry]()
        for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard let space = line.firstIndex(of: " ") else { throw ModelError.invalid("FTP 目录格式无效。") }
            let name = String(line[line.index(after: space)...]); var facts = [String: String]()
            for part in line[..<space].split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2 { facts[pair[0].lowercased()] = String(pair[1]) }
            }
            let kind = facts["type"]?.lowercased() ?? ""
            if kind == "cdir" || kind == "pdir" || !RemotePath.safeName(name) { continue }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"
            entries.append(RemoteFileEntry(name: name, size: UInt64(facts["size"] ?? "") ?? 0, modified: facts["modify"].flatMap { formatter.date(from: String($0.prefix(14))) }, directory: kind == "dir", symbolicLink: kind.contains("slink")))
        }
        return entries
    }
    static func parseLIST(_ data: Data) throws -> [RemoteFileEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw ModelError.invalid("FTP 文件名不是 UTF-8。"); }
        let unix = try NSRegularExpression(pattern: #"^([bcdlps-][rwxstST-]{9})[+@.]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+[A-Za-z]{3}\s+\d{1,2}\s+(?:\d{2}:\d{2}|\d{4})\s+(.*)$"#)
        let dos = try NSRegularExpression(pattern: #"^\d{2}-\d{2}-\d{2,4}\s+\d{1,2}:\d{2}(?:AM|PM)\s+(<DIR>|\d+)\s+(.*)$"#, options: [.caseInsensitive])
        var entries = [RemoteFileEntry]()
        for line in text.components(separatedBy: .newlines) where !line.isEmpty && !line.hasPrefix("total ") {
            let string = line as NSString, range = NSRange(location: 0, length: (line as NSString).length)
            let name: String, directory: Bool, symbolic: Bool, size: UInt64
            if let match = unix.firstMatch(in: line, range: range) {
                let permissions = string.substring(with: match.range(at: 1))
                symbolic = permissions.hasPrefix("l"); directory = permissions.hasPrefix("d")
                let rawName = string.substring(with: match.range(at: 3))
                name = symbolic ? rawName.components(separatedBy: " -> ")[0] : rawName
                size = UInt64(string.substring(with: match.range(at: 2))) ?? 0
            } else if let match = dos.firstMatch(in: line, range: range) {
                let kind = string.substring(with: match.range(at: 1)); directory = kind.uppercased() == "<DIR>"; symbolic = false
                size = UInt64(kind) ?? 0; name = string.substring(with: match.range(at: 2))
            } else { throw ModelError.invalid("FTP LIST 格式无法识别。"); }
            if RemotePath.safeName(name) { entries.append(RemoteFileEntry(name: name, size: size, modified: nil, directory: directory, symbolicLink: symbolic)) }
        }
        return entries
    }
    private func commandPath(_ path: String) throws -> String { try canonicalPath(path).dropFirst().description }
    func mkdir(_ path: String) throws { _ = try curl("/", directory: true, arguments: ["--quote", "MKD " + commandPath(path), "--list-only"]) }
    func rename(_ source: String, to destination: String) throws { _ = try curl("/", directory: true, arguments: ["--quote", "RNFR " + commandPath(source), "--quote", "RNTO " + commandPath(destination), "--list-only"]) }
    func remove(_ path: String, directory: Bool) throws { _ = try curl("/", directory: true, arguments: ["--quote", (directory ? "RMD " : "DELE ") + commandPath(path), "--list-only"]) }
    func upload(_ local: URL, to remote: String, progress: @escaping (UInt64, UInt64) -> Void) throws { try upload(local, to: remote, depth: 0, progress: progress) }
    private func upload(_ local: URL, to remote: String, depth: Int, progress: @escaping (UInt64, UInt64) -> Void) throws {
        guard depth <= 32, RemotePath.safeName(local.lastPathComponent) else { throw ModelError.invalid("目录嵌套过深或文件名无效。") }
        let info = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true else { throw ModelError.invalid("不自动上传符号链接。") }
        if info.isDirectory == true {
            try mkdir(remote)
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) { try upload(child, to: RemotePath.join(remote, child.lastPathComponent), depth: depth + 1, progress: progress) }
        } else {
            _ = try curl(remote, directory: false, arguments: ["--upload-file", local.path]); progress(UInt64(info.fileSize ?? 0), UInt64(info.fileSize ?? 0))
        }
    }
    func download(_ remote: String, to local: URL, progress: @escaping (UInt64, UInt64) -> Void) throws { try download(remote, to: local, depth: 0, progress: progress) }
    private func download(_ remote: String, to local: URL, depth: Int, progress: @escaping (UInt64, UInt64) -> Void) throws {
        guard depth <= 32 else { throw ModelError.invalid("目录嵌套过深。") }
        let parent = (remote as NSString).deletingLastPathComponent, name = (remote as NSString).lastPathComponent
        let info = try list(parent).first { $0.name == name }
        if info?.directory == true {
            guard !FileManager.default.fileExists(atPath: local.path) else { throw ModelError.invalid("本地目录已存在。") }
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            for entry in try list(remote) where !entry.symbolicLink { try download(RemotePath.join(remote, entry.name), to: local.appendingPathComponent(entry.name), depth: depth + 1, progress: progress) }
            return
        }
        let fd = Darwin.open(local.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ModelError.invalid("本地文件已存在或无法写入。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); var complete = false
        defer { try? handle.oshellClose(); if !complete { try? FileManager.default.removeItem(at: local) } }
        _ = try curl(remote, directory: false, sink: handle) { bytes in progress(bytes, info?.size ?? 0) }; try handle.oshellClose(); complete = true
    }
    func cancel() { lock.lock(); cancelled = true; let task = active; lock.unlock(); task?.cancel() }
}

final class SCPTransfer {
    private let profile: SessionProfile
    private var broker: AuthBroker?
    private let oneTimePassword: String?
    private let lease: SSHConnectionLease?
    private let knownHosts: URL
    private let lock = NSLock()
    private var process: FileProcess?
    private var cancelled = false
    init(profile: SessionProfile, knownHosts: URL, oneTimePassword: String? = nil, connectionGroup: SSHConnectionGroup? = nil) throws {
        lease = try connectionGroup.map { try SSHConnectionLease(group: $0, profile: profile) }
        self.oneTimePassword = connectionGroup == nil ? oneTimePassword : nil; self.profile = profile; self.knownHosts = knownHosts
    }
    func run(local: URL, remote: String, upload: Bool) throws {
        try RemotePath.validate(remote)
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        guard !wasCancelled else { throw ModelError.invalid("操作已取消。") }
        let broker: AuthBroker?
        if lease != nil { broker = nil }
        else { broker = try Thread.isMainThread ? AuthBroker(profile: profile, oneTimePassword: oneTimePassword) : DispatchQueue.main.sync { try AuthBroker(profile: profile, oneTimePassword: oneTimePassword) } }
        lock.lock(); self.broker = broker; lock.unlock()
        defer { DispatchQueue.main.async { broker?.stop() } }
        let shared = try lease?.group.arguments(for: profile, clone: true) ?? []
        var sourceArgs = shared + (try FileSSH.arguments(profile, knownHosts: knownHosts, reusingConnection: lease != nil)), args = (OpenSSHCapabilities.current.needsSCPLegacyFlag ? ["-O"] : []) + ["-r"]
        while !sourceArgs.isEmpty {
            let option = sourceArgs.removeFirst()
            if option == "-p" { args += ["-P", sourceArgs.removeFirst()] }
            else if option == "-l" { args += ["-o", "User=" + sourceArgs.removeFirst()] }
            else if ["-o", "-i", "-J"].contains(option) { args += [option, sourceArgs.removeFirst()] }
            else { args.append(option) }
        }
        // SCP's legacy protocol executes a remote scp command; quote the remote
        // path for that shell rather than interpolating arbitrary filenames.
        let endpoint = ConnectionValidation.bracket(profile.host) + ":" + ConnectionValidation.quote(remote)
        args += ["--"] + (upload ? [local.path, endpoint] : [endpoint, local.path])
        let task = FileProcess(executable: "/usr/bin/scp", arguments: args, environment: FileSSH.environment(broker))
        lock.lock()
        guard !cancelled else { lock.unlock(); throw ModelError.invalid("操作已取消。") }
        process = task; lock.unlock()
        try task.start(); task.closeInput(); _ = try task.outputToEnd()
    }
    func cancel() { lock.lock(); cancelled = true; let task = process, auth = broker; lock.unlock(); task?.cancel(); lease?.release(); DispatchQueue.main.async { auth?.stop() } }
    deinit { process?.cancel(); lease?.release(); let broker = broker; DispatchQueue.main.async { broker?.stop() } }
}
