// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Owns the receiver's final ZFIN -> OO exchange on a reliable, ordered SSH
/// stream. Only one ZFIN may enter that stream: a retry queued before OO can
/// otherwise arrive after sz has restored Bash's cooked terminal mode.
public struct ZmodemFinishHandshake {
    private var pendingOutput = Data()
    private var pendingO = false
    private var pendingTerminal = Data()
    private let expectedHostname: String?
    public private(set) var awaitingOO = false
    public private(set) var completed = false
    public private(set) var completedFromPrompt = false
    public init(expectedHostname: String? = nil) { self.expectedHostname = expectedHostname }
    public mutating func outgoing(_ bytes: Data) -> Data {
        guard !awaitingOO, !completed else { return Data() }
        pendingOutput.append(bytes)
        let marker = Data([42, 42, 24, 66])
        var output = Data()
        while let range = pendingOutput.range(of: marker) {
            output.append(pendingOutput[..<range.lowerBound])
            pendingOutput = Data(pendingOutput[range.lowerBound...])
            guard pendingOutput.count >= 18 else { return output }
            let hex = Array(pendingOutput.prefix(18).dropFirst(4))
            var header = [UInt8]()
            for index in stride(from: 0, to: 14, by: 2) {
                guard let value = UInt8(String(bytes: hex[index..<index+2], encoding: .ascii) ?? "", radix: 16) else { break }
                header.append(value)
            }
            if header.count == 7, header[0] == 8, ZmodemDetector.crc(header) == 0 {
                awaitingOO = true
                output.append(pendingOutput.prefix(18))
                // Emit the complete hex frame atomically, including its normal
                // CR/high-bit-LF trailer. Discard all subsequent helper output,
                // including retries coalesced in this very read or split later.
                output.append(contentsOf: [13, 138])
                pendingOutput.removeAll()
                return output
            }
            output.append(pendingOutput.removeFirst())
        }
        var retained = 0
        if !pendingOutput.isEmpty {
            for count in 1...min(3, pendingOutput.count) where pendingOutput.suffix(count) == marker.prefix(count) { retained = count }
        }
        output.append(pendingOutput.dropLast(retained))
        pendingOutput = Data(pendingOutput.suffix(retained))
        return output
    }
    public mutating func incoming(_ bytes: Data) -> (protocolBytes: Data, terminalBytes: Data) {
        if completed { return (Data(), bytes) }
        guard awaitingOO else { return (bytes, Data()) }
        let data = (pendingO ? Data([79]) : Data()) + bytes
        pendingO = false
        if let range = data.range(of: Data([79, 79])) {
            completed = true
            pendingTerminal.removeAll()
            return (Data([79, 79]), Data(data[range.upperBound...]))
        }
        pendingO = data.last == 79
        // Some SSH gateways/senders omit or consume OO but return the shell
        // immediately. After a CRC-valid receiver ZFIN, every file is closed.
        // Recognize only a prompt for the already known current host, never a
        // percentage, elapsed timeout, arbitrary text, or a host guessed here.
        if let expectedHostname {
            pendingTerminal.append(bytes)
            if pendingTerminal.count > 8192 { pendingTerminal = Data(pendingTerminal.suffix(8192)) }
            let start = pendingTerminal.lastIndex(where: { $0 == 10 || $0 == 13 || $0 == 138 }).map { pendingTerminal.index(after: $0) } ?? pendingTerminal.startIndex
            let candidate = Data(pendingTerminal[start...])
            var filter = PlainTextFilter()
            let visible = String(decoding: filter.consume(candidate), as: UTF8.self)
            if let host = TerminalHostname.fromPrompt(visible), RemoteHostIdentity.sameHost(host, expectedHostname) {
                completed = true; completedFromPrompt = true; pendingTerminal.removeAll()
                // This acknowledgement goes only to the LOCAL lrz process.
                // Preserve the peer's colored prompt and never send input to its shell.
                return (Data([79, 79]), candidate)
            }
        }
        // Header tails, status text and sender retries are not the OO ack.
        // Feeding them to lrz's ackbibi makes it retry immediately and can make
        // it exit before the genuine ack arrives.
        return (Data(), Data())
    }
}
