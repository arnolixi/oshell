// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

/// Both transports exchange one authenticated vault and require conditional writes.
public protocol SharedSyncTransport: AnyObject {
    func fetch() throws -> WebDAVObject?
    func put(_ data: Data, matching etag: String?) throws
    func cancel()
}
extension WebDAVClient: SharedSyncTransport {}

public final class DirectorySyncClient: SharedSyncTransport {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("configuration.json") }
    private let lock = NSLock()
    private var cancelled = false
    public init(directory: URL) { self.directory = directory.standardizedFileURL }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        guard !stopped else { throw ModelError.invalid("目录同步已取消，本地数据保留。") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ModelError.invalid("同步目录暂不可用，本地数据已保留。目录恢复后可重新同步。")
        }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("local-credential-key.json").path) else {
            throw ModelError.invalid("同步目录包含本机解密密钥，已停止同步。请选择只存放加密共享数据的目录。")
        }
        guard (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty else {
            throw ModelError.invalid("iCloud 已产生文件级冲突版本，未覆盖任何版本。请先在 Finder 保留并处理冲突副本，再同步。")
        }
    }
    private func stamp(_ data: Data) -> String { "\"" + PlatformDigest.sha256(data).map { String(format: "%02x", $0) }.joined() + "\"" }
    public func fetch() throws -> WebDAVObject? {
        try check()
        var error: NSError?, result: Result<WebDAVObject?, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { actual in
            result = Result {
                try check()
                guard let data = try SharedDataFile.readIfPresent(actual) else { return nil }
                guard SharedVault.isEncrypted(data) else { throw ModelError.invalid("同步文件未加密或格式错误，未覆盖本地配置。") }
                return WebDAVObject(data: data, etag: stamp(data))
            }
        }
        if let result { return try result.get() }
        throw error ?? ModelError.invalid("无法读取同步目录，本地数据已保留。") as NSError
    }
    public func put(_ data: Data, matching etag: String?) throws {
        try check()
        guard SharedVault.isEncrypted(data), data.count <= SharedVault.maximumSize else { throw ModelError.invalid("目录同步只接受加密数据包。") }
        var error: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { actual in
            result = Result {
                try check()
                let existing = try SharedDataFile.readIfPresent(actual)
                guard existing.map(stamp) == etag else { throw WebDAVFailure.conflict }
                if existing == nil { try SharedDataFile.create(data, at: actual) }
                else { try PrivateFile.write(data, to: actual) }
            }
        }
        if let result { try result.get(); return }
        throw error ?? ModelError.invalid("无法写入同步目录，本地数据已保留。") as NSError
    }
}
