// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

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
    public var entries: [SessionLink] = []
    public var folders: [String] = []
    public var visible = true
    public init() {}
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
        folders = allFolders
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
