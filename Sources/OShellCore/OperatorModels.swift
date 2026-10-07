// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public struct QuickCommand: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var group: String
    public var text: String
    public var appendReturn: Bool
    public init(name: String = "新命令", group: String = "常用", text: String = "", appendReturn: Bool = true) {
        self.name = name; self.group = group; self.text = text; self.appendReturn = appendReturn
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.isEmpty, text.utf8.count <= 1_048_576, !text.contains("\0") else { throw ModelError.invalid("请填写命令名称和内容，内容不能包含空字符或超过 1 MiB。") }
    }
}
public struct HighlightRule: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var pattern: String
    public var regex: Bool
    public var caseSensitive: Bool
    public var color: String
    public var enabled = true
    public init(pattern: String = "", regex: Bool = false, caseSensitive: Bool = false, color: String = "#FF5F56") {
        self.pattern = pattern; self.regex = regex; self.caseSensitive = caseSensitive; self.color = color
    }
    public func validate() throws {
        guard !pattern.isEmpty, pattern.utf8.count <= 512, color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw ModelError.invalid("请填写关键字或正则表达式（最多 512 字节）及有效颜色。") }
        if regex { _ = try NSRegularExpression(pattern: pattern.replacingOccurrences(of: "${hostname}", with: "example")) }
    }
}
public struct HighlightSet: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var rules: [HighlightRule]
    public init(name: String = "新突出显示集", rules: [HighlightRule] = []) { self.name = name; self.rules = rules }
    public static let standardID = UUID(uuidString: "F6C9AE44-0C05-450B-AB54-28F8AC88B314")!
    public static var standard: HighlightSet {
        var set = HighlightSet(name: "错误、警告与主机名", rules: [
            HighlightRule(pattern: "\\b(error|fatal|failed|panic)\\b", regex: true, color: "#FF5F56"),
            HighlightRule(pattern: "\\b(warn|warning)\\b", regex: true, color: "#FFAA33"),
            HighlightRule(pattern: "${hostname}", color: "#F5D547")])
        set.id = standardID; return set
    }
}
public struct HighlightMatch { public let range: NSRange; public let color: String }
/// Compiled once per configuration/hostname; bounded cache and matching budget.
public final class HighlightMatcher {
    private let expressions: [(NSRegularExpression, String)]
    private var cache = [String: [HighlightMatch]]()
    public init(set: HighlightSet, hostname: String) {
        expressions = set.rules.prefix(32).filter(\.enabled).compactMap { rule in
            let source = rule.pattern.replacingOccurrences(of: "${hostname}", with: rule.regex ? NSRegularExpression.escapedPattern(for: hostname) : hostname)
            guard !source.isEmpty, let expression = try? NSRegularExpression(pattern: rule.regex ? source : NSRegularExpression.escapedPattern(for: source), options: rule.caseSensitive ? [] : [.caseInsensitive]) else { return nil }
            return (expression, rule.color)
        }
    }
    public func matches(in text: String) -> [HighlightMatch] {
        guard !expressions.isEmpty, text.utf16.count <= 4096 else { return [] }
        if let result = cache[text] { return result }
        var result = [HighlightMatch]()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000
        for (expression, color) in expressions {
            expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: text.utf16.count)) { match, _, stop in
                if DispatchTime.now().uptimeNanoseconds > deadline || result.count >= 256 { stop.pointee = true; return }
                if let match, match.range.length > 0 { result.append(HighlightMatch(range: match.range, color: color)) }
            }
            if DispatchTime.now().uptimeNanoseconds > deadline { break }
        }
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[text] = result; return result
    }
}
public enum InputText {
    public static func normalized(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
    public static func isMultiline(_ text: String) -> Bool { normalized(text).contains("\n") }
    public static func bytes(_ text: String, bracketed: Bool, appendReturn: Bool = false) -> [UInt8] {
        let normalized = normalized(text)
        // Do not allow clipboard content to terminate bracketed-paste framing.
        let body = normalized.replacingOccurrences(of: "\u{1b}", with: "")
        if bracketed { return Array(("\u{1b}[200~" + body + "\u{1b}[201~" + (appendReturn ? "\r" : "")).utf8) }
        return Array((body.replacingOccurrences(of: "\n", with: "\r") + (appendReturn && !body.hasSuffix("\n") ? "\r" : "")).utf8)
    }
}
public struct FTPProfile: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name = "FTP 连接"
    public var host = ""
    public var port = 21
    public var username = "anonymous"
    public var encryptedPassword: EncryptedPassword?
    public var initialDirectory = "/"
    public init() {}
    public var credentialProfile: SessionProfile {
        var profile = SessionProfile(id: id, name: name, host: host, port: port, username: username)
        profile.encryptedPassword = encryptedPassword; return profile
    }
    public func validate() throws {
        guard !name.isEmpty, ConnectionValidation.host(host), (1...65535).contains(port), !username.contains(":"), !username.contains("\n"), !username.contains("\r"), !username.contains("\0") else { throw ModelError.invalid("FTP 名称、主机、端口或用户名无效。") }
        try RemotePath.validate(initialDirectory)
    }
}
public enum RemotePath {
    public static func validate(_ path: String) throws {
        guard !path.contains("\0"), !path.contains("\r"), !path.contains("\n"), path.utf8.count <= 8192 else { throw ModelError.invalid("文件路径包含不支持的控制字符或过长。") }
    }
    public static func join(_ directory: String, _ name: String) -> String { (directory.hasSuffix("/") ? directory : directory + "/") + name }
    public static func safeName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && !name.contains("\r") && !name.contains("\n") }
}
