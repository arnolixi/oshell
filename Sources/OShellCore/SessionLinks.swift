// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public enum SessionLinkItem: Hashable {
    case link(UUID), session(UUID), folder(String)
    public var key: String {
        switch self { case .link(let id): return "link:" + id.uuidString; case .session(let id): return "session:" + id.uuidString; case .folder(let path): return "folder:" + path }
    }
}

/// Bookmarks reference saved profiles; they never duplicate credentials.
public struct SessionLink: Codable, Equatable, Identifiable {
    public var id: UUID
    public var profileID: UUID
    public var name: String
    public var folder: String
    public init(id: UUID = UUID(), profileID: UUID, name: String, folder: String = "") {
        self.id = id; self.profileID = profileID; self.name = name; self.folder = SessionDirectory.normalize(folder)
    }
}
public struct SessionLinks: Codable {
    public static let rootDirectory = "Links"
    public static func containsDirectory(_ path: String) -> Bool { SessionDirectory.contains(path, in: rootDirectory) }
    public static func directory(for folder: String) -> String {
        [rootDirectory, SessionDirectory.normalize(folder)].filter { !$0.isEmpty }.joined(separator: "/")
    }
    public static func folder(for directory: String) -> String? {
        guard containsDirectory(directory) else { return nil }
        return directory == rootDirectory ? "" : String(directory.dropFirst(rootDirectory.count + 1))
    }
    public var entries: [SessionLink] = []
    public var folders: [String] = []
    public var visible = true
    public var rootOrder: [String] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case entries, folders, visible, rootOrder }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decodeIfPresent([SessionLink].self, forKey: .entries) ?? []
        folders = try values.decodeIfPresent([String].self, forKey: .folders) ?? []
        visible = try values.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        rootOrder = try values.decodeIfPresent([String].self, forKey: .rootOrder) ?? []
    }
    public var orderedRootItems: [SessionLinkItem] { orderedRootItems(profiles: []) }
    public func orderedRootItems(profiles: [SessionProfile]) -> [SessionLinkItem] {
        let defaults = allFolders.filter { SessionDirectory.parent($0).isEmpty }.map(SessionLinkItem.folder)
            + entries.filter { $0.folder.isEmpty }.map { SessionLinkItem.link($0.id) }
            + profiles.filter { $0.group == Self.rootDirectory }.map { SessionLinkItem.session($0.id) }
        let available = Dictionary(uniqueKeysWithValues: defaults.map { ($0.key, $0) })
        var seen = Set<String>()
        return (rootOrder + defaults.map(\.key)).compactMap { key in
            guard let item = available[key], seen.insert(key).inserted else { return nil }; return item
        }
    }
    public mutating func normalizeRootOrder(profiles: [SessionProfile]? = nil) {
        guard !rootOrder.isEmpty else { return }
        if let profiles { rootOrder = orderedRootItems(profiles: profiles).map(\.key) }
        else {
            let valid = Set(orderedRootItems.map(\.key))
            rootOrder = rootOrder.filter { valid.contains($0) || $0.hasPrefix("session:") }
            rootOrder += orderedRootItems.map(\.key).filter { !rootOrder.contains($0) }
        }
    }
    @discardableResult public mutating func reorderRoot(_ source: SessionLinkItem, before target: SessionLinkItem?, profiles: [SessionProfile] = []) throws -> Bool {
        let current = orderedRootItems(profiles: profiles)
        guard current.contains(source), target == nil || current.contains(target!) else { throw ModelError.invalid("链接栏项目已变化，请重新拖动。") }
        if source == target { return false }
        var reordered = current.filter { $0 != source }
        if let target, let index = reordered.firstIndex(of: target) { reordered.insert(source, at: index) }
        else { reordered.append(source) }
        guard reordered != current else { return false }
        rootOrder = reordered.map(\.key); return true
    }
    public var allFolders: [String] {
        var paths = Set<String>()
        for folder in folders + entries.map(\.folder) {
            var parts: [String] = []
            for part in SessionDirectory.normalize(folder).split(separator: "/") {
                parts.append(String(part)); paths.insert(parts.joined(separator: "/"))
            }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public mutating func normalize(profiles: [SessionProfile]) {
        let valid = Set(profiles.map(\.id)); var ids = Set<UUID>(), locations = Set<String>()
        entries = entries.filter { valid.contains($0.profileID) }.compactMap { entry in
            var value = entry; value.folder = SessionDirectory.normalize(value.folder)
            value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.name.isEmpty { value.name = profiles.first { $0.id == value.profileID }?.name ?? "会话" }
            guard ids.insert(value.id).inserted, locations.insert(value.profileID.uuidString + "/" + value.folder).inserted else { return nil }
            return value
        }
        folders = allFolders; normalizeRootOrder(profiles: profiles)
    }
    public mutating func add(profileID: UUID, name: String, folder: String = "") {
        let folder = SessionDirectory.normalize(folder)
        if let index = entries.firstIndex(where: { $0.profileID == profileID && $0.folder == folder }) { entries[index].name = name }
        else { entries.append(SessionLink(profileID: profileID, name: name, folder: folder)) }
        folders = allFolders; visible = true
    }
    public mutating func renameFolder(_ old: String, to new: String) throws {
        let new = SessionDirectory.normalize(new)
        guard !old.isEmpty, !new.isEmpty, old != new, !SessionDirectory.contains(new, in: old), !allFolders.contains(new) else {
            throw ModelError.invalid("文件夹名称无效或已存在。")
        }
        func moved(_ value: String) -> String { SessionDirectory.contains(value, in: old) ? new + value.dropFirst(old.count) : value }
        rootOrder = rootOrder.map { key in key.hasPrefix("folder:") ? "folder:" + moved(String(key.dropFirst(7))) : key }
        folders = allFolders.map(moved)
        for index in entries.indices { entries[index].folder = moved(entries[index].folder) }
        folders = allFolders
    }
    public mutating func removeFolder(_ folder: String) {
        guard !folder.isEmpty else { return }
        entries.removeAll { SessionDirectory.contains($0.folder, in: folder) }
        folders = allFolders.filter { !SessionDirectory.contains($0, in: folder) }
    }
}

extension Configuration {
    /// Existing relative link folders are projected beneath /Links without
    /// moving profiles, copying credentials, or changing reference identities.
    public mutating func normalizeSessionLinkDirectories() {
        let paths = SessionDirectory.all(self)
        sessionLinks.folders += paths.compactMap { SessionLinks.folder(for: $0) }.filter { !$0.isEmpty }
        sessionLinks.folders = sessionLinks.allFolders
        sessionLinks.normalizeRootOrder(profiles: profiles)
        // A single owner for Links directories prevents a deleted folder from
        // reappearing through a stale second copy in the ordinary catalog.
        directories = paths.filter { !SessionLinks.containsDirectory($0) }
    }
}
