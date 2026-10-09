// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

public struct StaticUpdateRequestError: Error, LocalizedError {
    public let status: Int
    public let retryAt: Date?
    public init(status: Int, retryAt: Date? = nil) { self.status = status; self.retryAt = retryAt }
    public var errorDescription: String? {
        if status == 404 { return "更新站点尚未部署，或仓库地址不正确。请检查更新设置或联系维护者。" }
        if status == 403 || status == 429 {
            let time = retryAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) }
            return "更新服务暂时限制访问。" + (time.map { "请在 \($0) 后重试。" } ?? "请稍后重试，避免连续点击。")
        }
        return "静态更新服务返回 HTTP \(status)，请稍后重试。"
    }
}

/// Per-source, in-memory cache. Expired content is never passed off as a successful new check.
public final class UpdateMetadataCache {
    private let lock = NSLock(), clock: () -> Date
    private var cached: (Data, Date)?, failed: (Error, Date)?
    public init(clock: @escaping () -> Date = Date.init) { self.clock = clock }
    public func value(load: () throws -> Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if let cached, now < cached.1 { return cached.0 }
        if let failed, now < failed.1 { throw failed.0 }
        do {
            let data = try load()
            cached = (data, clock().addingTimeInterval(300)); failed = nil; return data
        } catch {
            let date = clock()
            let delay = (error as? StaticUpdateRequestError)?.retryAt.map { min(86_400, max(60, $0.timeIntervalSince(date))) } ?? 60
            cached = nil; failed = (error, date.addingTimeInterval(delay)); throw error
        }
    }
}
