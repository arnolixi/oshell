// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin

/// Bootstrap stays on this Mac. Only portable application data enters the shared directory.
public final class StorageLocation {
    public enum Mode: String, Codable { case migrate, existing }
    public struct Pending: Codable, Equatable {
        public let path: String
        public let mode: Mode
        public init(path: String, mode: Mode) { self.path = path; self.mode = mode }
    }
    private struct State: Codable { var current: String?; var pending: Pending? }
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OShell")
    }
    public static var localStateDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        let harness = CommandLine.arguments.contains { $0.hasSuffix("-test") || $0.hasPrefix("--memory-") } || environment.keys.contains { $0.hasSuffix("_TEST_ROOT") }
        if harness, let override = environment["OSHELL_DATA_DIR"] { return URL(fileURLWithPath: override) }
        return defaultDirectory
    }
    public static func resolvedDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] { return URL(fileURLWithPath: override) }
        return try StorageLocation().activeDirectory()
    }
    public let base: URL
    private var stateURL: URL { base.appendingPathComponent("storage-location.json") }
    public init(base: URL = StorageLocation.defaultDirectory) { self.base = base.standardizedFileURL }
    private func read() throws -> State {
        guard let data = try SharedDataFile.readIfPresent(stateURL) else { return State() }
        return try JSONDecoder().decode(State.self, from: data)
    }
    private func write(_ state: State) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(state), to: stateURL)
    }
    public func activeDirectory() throws -> URL {
        let state = try read()
        guard let path = state.current else { return base }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw ModelError.invalid("自定义数据目录不可用，请先恢复目录或等待 iCloud 下载完成：\(url.path)") }
        // Never create a new, empty configuration over a missing cloud database.
        guard try SharedDataFile.readIfPresent(url.appendingPathComponent("configuration.json")) != nil else { throw ModelError.invalid("自定义目录缺少 configuration.json，已停止启动以保护现有数据。") }
        guard !FileManager.default.fileExists(atPath: url.appendingPathComponent("local-credential-key.json").path) else { throw ModelError.invalid("共享目录含有本机解密密钥，已阻止加载。请在本地用主密码转换后迁移到新的空目录。") }
        return url
    }
    public func restoreDefaultDirectory() throws -> URL {
        guard try SharedDataFile.readIfPresent(base.appendingPathComponent("configuration.json")) != nil else { throw ModelError.invalid("默认本地目录没有可恢复的配置。") }
        try write(State(current: nil, pending: nil)); return base
    }
    public func pending() throws -> Pending? { try read().pending }
    public func validate(_ choice: Pending, master: String? = nil) throws {
        guard master != nil else { throw ModelError.invalid("使用共享或自定义目录必须先解锁主密码。") }
        let source = try activeDirectory().resolvingSymlinksInPath()
        let target = URL(fileURLWithPath: choice.path).standardizedFileURL.resolvingSymlinksInPath()
        guard source.path != target.path else { throw ModelError.invalid("目标已经是当前数据目录。") }
        guard !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/") else { throw ModelError.invalid("请选择独立的数据目录，不能选择当前目录的子目录或上级目录。") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &directory), directory.boolValue else { throw ModelError.invalid("请选择已经存在的文件夹。") }
        if choice.mode == .migrate {
            let config = try Self.validateData(at: source, master: master)
            try SharingProtection.require(config)
            let names = try FileManager.default.contentsOfDirectory(atPath: target.path).filter { $0 != ".DS_Store" }
            guard names.isEmpty else { throw ModelError.invalid("迁移目标必须是空文件夹，不会覆盖已有数据。若要共用另一台 Mac 的数据，请选择“使用已有数据目录”。") }
        } else {
            guard target.path == base.resolvingSymlinksInPath().path || !FileManager.default.fileExists(atPath: target.appendingPathComponent("local-credential-key.json").path) else { throw ModelError.invalid("目标共享目录包含本机解密密钥，请迁移到新的加密目录。") }
            _ = try Self.validateData(at: target, master: master)
        }
    }
    public func schedule(_ choice: Pending?, master: String? = nil) throws {
        if let choice { try validate(choice, master: master) }
        var state = try read(); state.pending = choice; try write(state)
    }
    public static func validateData(at directory: URL, master: String? = nil) throws -> Configuration {
        guard try SharedDataFile.readIfPresent(directory.appendingPathComponent("configuration.json")) != nil else { throw ModelError.invalid("目录中没有 OShell 的 configuration.json。") }
        let configuration = try ConfigurationStore(directory: directory, masterPassword: master).load()
        try SharingProtection.require(configuration)
        if let master { try MasterPasswordProtection.verifyStartup(configuration, password: master) }
        return configuration
    }
    /// Called only on launch, while neither source nor destination is in use locally.
    public func activatePending(master: String? = nil) throws -> URL {
        var state = try read()
        guard let choice = state.pending else { return try activeDirectory() }
        try validate(choice, master: master)
        let source = try activeDirectory(), target = URL(fileURLWithPath: choice.path).standardizedFileURL.resolvingSymlinksInPath()
        var locks = [Int32]()
        defer { locks.forEach { close($0) } }
        for directory in [source, target] {
            locks.append(try LaunchEndpoint.lock("server.lock", directory: LaunchEndpoint.directory(for: directory), nonblocking: true))
        }
        var created = [(URL, Data)]()
        do {
            if choice.mode == .migrate {
                // Source remains intact, including when the copy or bootstrap commit fails.
                guard let master else { throw ModelError.invalid("迁移共享数据必须输入主密码。") }
                let config = try Self.validateData(at: source, master: master)
                let data = try SharedVault.encode(config, password: master), destination = target.appendingPathComponent("configuration.json")
                try SharedDataFile.create(data, at: destination); created.append((destination, data))
                _ = try Self.validateData(at: target, master: master)
            }
            state.current = target.path == base.path ? nil : target.path; state.pending = nil
            try write(state)
            return target
        } catch {
            // Roll back only files this operation created and that remain unchanged.
            for (url, data) in created.reversed() where (try? SharedDataFile.readIfPresent(url)) == data { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}

public enum SharedDataFile {
    /// Do not treat an evicted iCloud placeholder as an empty/new configuration.
    public static func readIfPresent(_ url: URL) throws -> Data? {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status == .notDownloaded {
            try? fm.startDownloadingUbiquitousItem(at: url)
            throw ModelError.invalid("数据仍在 iCloud 云端，已请求下载。请下载完成后重试。")
        }
        if !fm.fileExists(atPath: url.path) {
            if fm.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud").path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                throw ModelError.invalid("数据仍在 iCloud 云端，请先在 Finder 下载该目录后重试。")
            }
            return nil
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ModelError.invalid("无法读取数据文件：\(url.lastPathComponent)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.oshellClose() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 64 * 1024 * 1024 else { throw ModelError.invalid("数据文件类型或大小不正确：\(url.lastPathComponent)") }
        return try handle.oshellRead(upToCount: 64 * 1024 * 1024 + 1)
    }
    public static func create(_ data: Data, at url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".oshell-copy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try PrivateFile.write(data, to: staging)
        // Atomic no-replace publication; another device's existing file is never replaced.
        guard renamex_np(staging.path, url.path, UInt32(RENAME_EXCL)) == 0 else { throw ModelError.invalid("目标文件已存在或无法写入，未覆盖数据：\(url.lastPathComponent)") }
    }
}
