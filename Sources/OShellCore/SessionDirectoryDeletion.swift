// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public struct SessionDirectoryDeletion {
    public let configuration: Configuration
    public let sessionCount: Int
    public let subdirectoryCount: Int
    public let linkCount: Int
    public var requiresConfirmation: Bool { sessionCount > 0 || subdirectoryCount > 0 || linkCount > 0 }
}

extension SessionDirectory {
    /// Build a deletion snapshot without changing saved data or live connections.
    public static func deleting(_ configuration: Configuration, directory: String) throws -> SessionDirectoryDeletion {
        let paths = all(configuration)
        guard !directory.isEmpty, directory != SessionLinks.rootDirectory, paths.contains(directory) else {
            throw ModelError.invalid("不能删除会话根目录、/Links 根目录或已不存在的目录。")
        }
        let removed = Set(configuration.profiles.filter { contains($0.group, in: directory) }.map(\.id))
        let removedLinks = configuration.sessionLinks.entries.filter {
            removed.contains($0.profileID) || contains(SessionLinks.directory(for: $0.folder), in: directory)
        }
        let linkIDs = Set(removedLinks.map(\.id))
        var result = configuration
        result.profiles.removeAll { removed.contains($0.id) }
        result.sessionLinks.entries.removeAll { linkIDs.contains($0.id) }
        // Materialize surviving implicit parents so deleting their last child
        // does not silently delete an additional, unconfirmed directory.
        let retained = paths.filter { !contains($0, in: directory) }
        result.directories = retained.filter { !SessionLinks.containsDirectory($0) }
        result.sessionLinks.folders = retained.compactMap { SessionLinks.folder(for: $0) }.filter { !$0.isEmpty }
        result.sessionLinks.normalize(profiles: result.profiles)
        result.normalizeSessionLinkDirectories()
        return SessionDirectoryDeletion(configuration: result, sessionCount: removed.count,
                                        subdirectoryCount: paths.filter { $0 != directory && contains($0, in: directory) }.count,
                                        linkCount: removedLinks.count)
    }
}
