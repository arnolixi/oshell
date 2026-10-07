// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Payload counters reported by the bundled lrz/lsz, never SSH/protocol wire bytes.
public struct ZmodemProgress: Equatable {
    public var filename: String = ""
    public var bytes: Int64 = 0
    public var total: Int64?
    public var bytesPerSecond: Int64 = 0
    public var fraction: Double? {
        guard let total, total >= 0 else { return nil }
        return total == 0 ? 1 : min(1, max(0, Double(bytes) / Double(total)))
    }
    public init() {}
}

/// stderr is a CR/LF stream; retain fragmented UTF-8 and ignore verbose diagnostics.
public struct ZmodemProgressParser {
    private var pending = Data()
    private var discarding = false
    private var current = ZmodemProgress()
    private let uploadSizes: [String: Int64]
    private static let counters = try! NSRegularExpression(pattern: #"^Bytes (?:Sent|received):\s*(\d+)(?:/\s*(\d+))?\s+BPS:\s*(\d+)(?:\s|$)"#)
    public init(uploadSizes: [String: Int64] = [:]) { self.uploadSizes = uploadSizes }
    public mutating func consume(_ data: Data, end: Bool = false) -> [ZmodemProgress] {
        var updates = [ZmodemProgress]()
        for byte in data {
            if byte == 13 || byte == 10 {
                if !discarding, let update = parse() { updates.append(update) }
                pending.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if pending.count < 16384 { pending.append(byte) }
                else { pending.removeAll(keepingCapacity: true); discarding = true }
            }
        }
        if end {
            if !discarding, let update = parse() { updates.append(update) }
            pending.removeAll(); discarding = false
        }
        return updates
    }
    private mutating func parse() -> ZmodemProgress? {
        let line = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        for prefix in ["Sending: ", "Receiving: "] where line.hasPrefix(prefix) {
            current = ZmodemProgress()
            current.filename = String(line.dropFirst(prefix.count))
            current.total = uploadSizes[current.filename]
            return current
        }
        let ns = line as NSString
        guard let match = Self.counters.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let bytes = Int64(ns.substring(with: match.range(at: 1))),
              let speed = Int64(ns.substring(with: match.range(at: 3))) else { return nil }
        current.bytes = bytes; current.bytesPerSecond = speed
        if match.range(at: 2).location != NSNotFound { current.total = Int64(ns.substring(with: match.range(at: 2))) }
        return current
    }
}
