// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// Literal AND search over display metadata only; never inspect credentials.
public struct SessionSearchQuery {
    public let terms: [String]
    public let isValid: Bool
    public var isEmpty: Bool { terms.isEmpty && isValid }
    public init(_ text: String) {
        guard text.utf8.count <= 4096 else { isValid = false; terms = []; return }
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        isValid = text.utf8.count <= 4096 && parts.count <= 32
        terms = isValid ? parts.map(Self.normalize) : []
    }
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func metadata(_ profile: SessionProfile) -> String {
        normalize([profile.name, profile.host, profile.username, SessionDirectory.display(profile.group), profile.kind.title, profile.kind.rawValue, profile.kind == .local ? "本地终端" : String(profile.port)].joined(separator: " "))
    }
    public func matches(normalized text: String) -> Bool { isValid && terms.allSatisfy { text.contains($0) } }
}
