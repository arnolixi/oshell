// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Detects printable output without allocating a copy or counting OSC/CSI payloads.
/// State is retained across PTY chunks, including split terminal control strings.
public struct OutputActivity {
    private enum State { case text, escape, intermediate, csi, string, stringEscape }
    private var state = State.text
    public init() {}
    public mutating func consume(_ data: Data) -> Bool {
        var visible = false
        for byte in data {
            switch state {
            case .text:
                if byte == 27 { state = .escape }
                else if byte == 7 || (byte > 32 && byte != 127) { visible = true }
            case .escape:
                if byte == 91 { state = .csi }
                else if [93, 80, 94, 95, 88].contains(byte) { state = .string }
                else if (0x20...0x2f).contains(byte) { state = .intermediate }
                else { state = .text }
            case .intermediate:
                if (0x30...0x7e).contains(byte) { state = .text }
            case .csi:
                if byte == 27 { state = .escape }
                else if (0x40...0x7e).contains(byte) { state = .text }
            case .string:
                if byte == 7 { state = .text }
                else if byte == 27 { state = .stringEscape }
            case .stringEscape:
                if byte == 92 { state = .text }
                else if byte != 27 { state = .string }
            }
        }
        return visible
    }
}
