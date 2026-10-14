// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import Foundation

/// POSIX mode formatting shared by SFTP attributes and FTP UNIX listings.
enum RemoteFilePermissions {
    static func display(_ mode: UInt32) -> String {
        let type: String
        switch mode & 0xf000 {
        case 0x4000: type = "d"
        case 0xa000: type = "l"
        case 0x2000: type = "c"
        case 0x6000: type = "b"
        case 0x1000: type = "p"
        case 0xc000: type = "s"
        default: type = "-"
        }
        var text = type
        for (read, write, execute, special, on, off): (UInt32, UInt32, UInt32, UInt32, String, String) in [
            (0o400, 0o200, 0o100, 0o4000, "s", "S"),
            (0o040, 0o020, 0o010, 0o2000, "s", "S"),
            (0o004, 0o002, 0o001, 0o1000, "t", "T")
        ] {
            text += mode & read != 0 ? "r" : "-"
            text += mode & write != 0 ? "w" : "-"
            text += mode & special != 0 ? (mode & execute != 0 ? on : off) : (mode & execute != 0 ? "x" : "-")
        }
        return text + " (" + String(format: "%04o", mode & 0o7777) + ")"
    }
    static func octal(_ text: String?) -> UInt32? {
        guard let text, !text.isEmpty, text.count <= 6,
              text.allSatisfy({ "01234567".contains($0) }),
              let value = UInt32(text, radix: 8), value <= 0o7777 else { return nil }
        return value
    }
    static func symbolic(_ text: String) -> UInt32? {
        let chars = Array(text)
        let types: [Character: UInt32] = ["-": 0x8000, "d": 0x4000, "l": 0xa000, "c": 0x2000, "b": 0x6000, "p": 0x1000, "s": 0xc000]
        guard chars.count == 10, var mode = types[chars[0]] else { return nil }
        for group in 0..<3 {
            let start = 1 + group * 3, shift = (2 - group) * 3
            guard chars[start] == "r" || chars[start] == "-", chars[start + 1] == "w" || chars[start + 1] == "-" else { return nil }
            if chars[start] == "r" { mode |= 4 << shift }
            if chars[start + 1] == "w" { mode |= 2 << shift }
            let executable = chars[start + 2]
            let lower: Character = group == 2 ? "t" : "s", upper: Character = group == 2 ? "T" : "S"
            guard [Character("-"), "x", lower, upper].contains(executable) else { return nil }
            if executable == "x" || executable == lower { mode |= 1 << shift }
            if executable == lower || executable == upper { mode |= [UInt32(0o4000), 0o2000, 0o1000][group] }
        }
        return mode
    }
}

/// Only conventional UNIX long listings are interpreted. Other server formats
/// leave the optional names unknown; SFTP's numeric attributes remain authoritative.
struct RemoteUnixListing {
    let mode: UInt32
    let owner: String
    let group: String
    let size: UInt64
    let name: String
    private static let pattern = try! NSRegularExpression(pattern: #"^([bcdlps-][rwxstST-]{9})[+@.]?\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s+[A-Za-z]{3}\s+\d{1,2}\s+(?:\d{2}:\d{2}(?::\d{2})?|\d{4})\s+(.*)$"#)
    init?(_ line: String) {
        let text = line as NSString
        guard let match = Self.pattern.firstMatch(in: line, range: NSRange(location: 0, length: text.length)),
              let mode = RemoteFilePermissions.symbolic(text.substring(with: match.range(at: 1))),
              let size = UInt64(text.substring(with: match.range(at: 4))) else { return nil }
        self.mode = mode; self.size = size
        owner = text.substring(with: match.range(at: 2)); group = text.substring(with: match.range(at: 3))
        name = text.substring(with: match.range(at: 5))
    }
}
