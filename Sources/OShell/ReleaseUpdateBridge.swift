// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin
import OShellCore

/// A process-private adapter for Sparkle's HTTP feed interface. Nothing is
/// published as XML: signed bytes are read from a static GitHub Pages document.
final class ReleaseUpdateBridge {
    let url: URL
    private var listener: DispatchSourceRead?
    private let queue = DispatchQueue(label: "OShell.update.bridge")
    private let pending = DispatchSemaphore(value: 2)
    private let path: String
    private let load: () throws -> Data
    func prefetch() throws { _ = try load() }
    init(load: @escaping () throws -> Data) throws {
        self.load = load
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ModelError.invalid("无法创建本机更新通道。") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard bound == 0, named == 0, listen(fd, 2) == 0 else { close(fd); throw ModelError.invalid("无法启动本机更新通道。") }
        path = "/" + UUID().uuidString; url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))\(path)")!
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil); guard client >= 0 else { return }
                guard let self, self.pending.wait(timeout: .now()) == .success else { close(client); continue }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC); _ = fcntl(client, F_SETFL, 0)
                var timeout = timeval(tv_sec: 3, tv_usec: 0), noSignal: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global(qos: .utility).async { [pending = self.pending, path = self.path] in
                    defer { close(client); pending.signal() }
                    var request = Data(), bytes = [UInt8](repeating: 0, count: 2048)
                    while request.count < 8192 {
                        let count = recv(client, &bytes, min(bytes.count, 8192 - request.count), 0)
                        guard count > 0 else { return }; request.append(contentsOf: bytes.prefix(count))
                        if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
                    }
                    let first = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                    guard first.count == 3, first[0] == "GET", first[1].split(separator: "?", maxSplits: 1).first.map(String.init) == path else { Self.respond(client, status: "404 Not Found", data: Data()); return }
                    do {
                        let data = try load(); guard data.count <= 32_768 else { throw ModelError.invalid("更新信息过大。") }
                        Self.respond(client, status: "200 OK", data: data)
                    } catch { Self.respond(client, status: "503 Service Unavailable", data: Data(error.localizedDescription.utf8)) }
                }
            }
        }
        source.setCancelHandler { close(fd) }; source.resume(); listener = source
    }
    convenience init(source: UpdateSource, flavor: UpdateFlavor) throws {
        let cache = UpdateMetadataCache()
        try self.init { try cache.value { try GitHubReleaseUpdate.readStatic(StaticUpdateRequest.fetch(source.staticMetadataURL), source: source, flavor: flavor).signedFeed } }
    }
    private static func respond(_ fd: Int32, status: String, data: Data) {
        let response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/xml; charset=utf-8\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + data
        response.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }; sent += count
            }
        }
    }
    func stop() { listener?.cancel(); listener = nil }
    deinit { stop() }
}

private final class StaticUpdateRequest: NSObject, URLSessionDataDelegate {
    private let done = DispatchSemaphore(value: 0), lock = NSLock()
    private var data = Data(), response: HTTPURLResponse?, failure: Error?
    static func fetch(_ url: URL) throws -> Data {
        let request = StaticUpdateRequest(), config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25; config.urlCache = nil
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: request, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var input = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        input.setValue("application/json", forHTTPHeaderField: "Accept")
        input.setValue("OShell-Update", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: input).resume()
        guard request.done.wait(timeout: .now() + 28) == .success else { throw ModelError.invalid("连接更新站点超时，请检查网络或代理后重试。") }
        request.lock.lock(); defer { request.lock.unlock() }
        if let error = request.failure { throw error }
        guard request.response?.statusCode == 200 else {
            let response = request.response
            let retry = response?.allHeaderFields.first(where: { String(describing: $0.key).lowercased() == "retry-after" }).map { String(describing: $0.value) }.flatMap(TimeInterval.init).map { Date().addingTimeInterval(min(86_400, max(0, $0))) }
            throw StaticUpdateRequestError(status: response?.statusCode ?? 0, retryAt: retry)
        }
        return request.data
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); self.response = response as? HTTPURLResponse; lock.unlock()
        completionHandler(response.expectedContentLength > 1_048_576 ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + chunk.count > 1_048_576 { failure = ModelError.invalid("静态更新信息过大。"); dataTask.cancel() }
        else { data.append(chunk) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); if failure == nil { failure = error }; lock.unlock(); done.signal()
    }
}
