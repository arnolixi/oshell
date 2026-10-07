// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin

public enum UpdateFlavor: String {
    case intel = "macOS10.13-Intel", arm64 = "macOS13-arm64"
    public static func select(appleSilicon: Bool, majorOS: Int) -> UpdateFlavor { appleSilicon && majorOS >= 13 ? .arm64 : .intel }
    public static var current: UpdateFlavor {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        let appleSilicon = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        return select(appleSilicon: appleSilicon, majorOS: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
    public var feedName: String { "OShell-\(rawValue).xml" }
}
public struct UpdateSource: Equatable {
    public let repository: String
    public init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https://") {
            guard let url = URLComponents(string: value), url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { throw ModelError.invalid("请输入公开 GitHub 仓库地址，例如 https://github.com/owner/repo。") }
            value = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count <= 39, pieces[1].count <= 100,
              pieces[0].range(of: "^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$", options: .regularExpression) != nil,
              pieces[1].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
              pieces[1] != ".", pieces[1] != ".." else { throw ModelError.invalid("仓库格式应为 owner/repo，或对应的 GitHub HTTPS 地址。") }
        repository = value
    }
    public func feedURL(for flavor: UpdateFlavor) -> URL { URL(string: "https://github.com/\(repository)/releases/latest/download/\(flavor.feedName)")! }
    public func acceptsArchive(_ url: URL, flavor: UpdateFlavor) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              url.path.lowercased().hasPrefix("/\(repository.lowercased())/releases/download/"), url.pathExtension == "zip" else { return false }
        let segments = url.path.split(separator: "/")
        guard segments.count == 6, segments[4] != ".", segments[4] != ".." else { return false }
        let suffix = "-\(flavor.rawValue)-update.zip"
        return url.lastPathComponent.hasPrefix("OShell-") && url.lastPathComponent.hasSuffix(suffix)
    }
}
