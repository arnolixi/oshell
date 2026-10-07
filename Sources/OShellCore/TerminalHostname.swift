// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Display-only host hints. Never use these values for SSH identity or file I/O.
public enum TerminalHostname {
    private static let userHost = try! NSRegularExpression(pattern: #"^\s*\[?[^\s@\[\]:]{1,64}@([A-Za-z0-9][A-Za-z0-9_.-]{0,252})(?=[:\s\]]|$)"#)
    private static let bracketPrompt = try! NSRegularExpression(pattern: #"^\s*\[[^\s@\[\]:]{1,64}@([A-Za-z0-9][A-Za-z0-9_.-]{0,252})\s+[^\r\n\]]*\]\s*[#$%>]\s*$"#)
    private static let colonPrompt = try! NSRegularExpression(pattern: #"^\s*[^\s@\[\]:]{1,64}@([A-Za-z0-9][A-Za-z0-9_.-]{0,252}):[^\r\n]*[#$%>]\s*$"#)
    private static let spacePrompt = try! NSRegularExpression(pattern: #"^\s*[^\s@\[\]:]{1,64}@([A-Za-z0-9][A-Za-z0-9_.-]{0,252})\s+[^\r\n]*[#$%>]\s*$"#)
    private static func captured(_ text: String, _ pattern: NSRegularExpression) -> String? {
        guard text.utf8.count <= 2048, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let host = String(text[range]); return valid(host) ? host : nil
    }
    public static func valid(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && ConnectionValidation.host(host) && host != "." && host != ".."
    }
    public static func fromTitle(_ text: String) -> String? { captured(text, userHost) }
    public static func fromPrompt(_ text: String) -> String? { captured(text, bracketPrompt) ?? captured(text, colonPrompt) ?? captured(text, spacePrompt) }
    public static func fromDirectory(_ directory: String) -> String? {
        guard directory.utf8.count <= 8192, let url = URL(string: directory), url.scheme == "file", let host = url.host,
              valid(host), host.lowercased() != "localhost" else { return nil }
        return host
    }
}
