// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

extension SessionDirectory {
    public static func childPath(named name: String, in parent: String) throws -> String {
        let component = name.trimmingCharacters(in: .whitespaces)
        guard !component.isEmpty, component != ".", component != "..",
              !component.contains("/"), !component.contains("\\"), component.utf8.count <= 255,
              !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ModelError.invalid("请填写单个目录名称，不能包含 /、\\、控制字符，也不能使用 . 或 ..；名称最多 255 字节。")
        }
        return [normalize(parent), component].filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// /Links owns references. Dropping an ordinary session/directory there
    /// adds references without moving its source; other moves retain identity.
    public static func moving(_ configuration: Configuration, profileIDs: [UUID], directories: [String], linkIDs: [UUID] = [], to destination: String) throws -> Configuration? {
        let paths = all(configuration), existing = Set(paths), ids = Set(profileIDs), links = Set(linkIDs), requested = Set(directories)
        guard destination.isEmpty || existing.contains(destination) else { throw ModelError.invalid("目标目录已不存在，请重新选择。") }
        guard !ids.isEmpty || !requested.isEmpty || !links.isEmpty else { return nil }
        guard ids.isSubset(of: Set(configuration.profiles.map(\.id))), links.isSubset(of: Set(configuration.sessionLinks.entries.map(\.id))),
              !requested.contains(""), requested.isSubset(of: existing) else { throw ModelError.invalid("所选会话或目录已发生变化，请重新选择。") }
        guard !requested.contains(SessionLinks.rootDirectory) else { throw ModelError.invalid("/Links 是快捷链接根目录，不能移动或重命名。") }
        let roots = requested.filter { path in !requested.contains { $0 != path && contains(path, in: $0) } }
        let intoLinks = SessionLinks.containsDirectory(destination)
        guard intoLinks || (links.isEmpty && !roots.contains(where: SessionLinks.containsDirectory)) else {
            throw ModelError.invalid("快捷引用和快捷链接目录只能在 /Links 内移动，源会话位置保持不变。")
        }
        var replacements = [String: String](), copies = [String: String](), targets = Set<String>()
        for old in roots {
            guard !contains(destination, in: old) else { throw ModelError.invalid("不能将目录移动到自身或其子目录中。") }
            let leaf = String(old.split(separator: "/").last!)
            let next = [destination, leaf].filter { !$0.isEmpty }.joined(separator: "/")
            if next == old { continue }
            guard !existing.contains(next), targets.insert(next).inserted else { throw ModelError.invalid("目标位置已有同名目录“\(leaf)”，未移动任何项目。") }
            if intoLinks && !SessionLinks.containsDirectory(old) { copies[old] = next }
            else { replacements[old] = next }
        }
        func remap(_ path: String) -> String {
            for (old, next) in replacements where contains(path, in: old) { return next + String(path.dropFirst(old.count)) }
            return path
        }
        var value = configuration, changed = !replacements.isEmpty || !copies.isEmpty
        value.directories = configuration.directories.map(remap)
        value.sessionLinks.folders = configuration.sessionLinks.allFolders.compactMap { SessionLinks.folder(for: remap(SessionLinks.directory(for: $0))) }
        func addReference(_ profile: SessionProfile, at directory: String) {
            guard let folder = SessionLinks.folder(for: directory), !value.sessionLinks.entries.contains(where: { $0.profileID == profile.id && $0.folder == folder }) else { return }
            value.sessionLinks.add(profileID: profile.id, name: profile.name, folder: folder); changed = true
        }
        for (old, next) in copies {
            value.sessionLinks.folders += paths.filter { contains($0, in: old) }.compactMap { SessionLinks.folder(for: next + String($0.dropFirst(old.count))) }
            for profile in configuration.profiles where contains(profile.group, in: old) { addReference(profile, at: next + String(profile.group.dropFirst(old.count))) }
        }
        for index in value.profiles.indices {
            let profile = value.profiles[index]
            let withinDirectory = roots.contains { contains(profile.group, in: $0) }
            if intoLinks, ids.contains(profile.id), !withinDirectory { addReference(profile, at: destination) }
            let next = !intoLinks && ids.contains(profile.id) && !withinDirectory ? destination : remap(profile.group)
            if next != profile.group { changed = true; value.profiles[index].group = next }
        }
        for index in value.sessionLinks.entries.indices {
            let entry = value.sessionLinks.entries[index], origin = SessionLinks.directory(for: entry.folder)
            let next = links.contains(entry.id) && !roots.contains(where: { contains(origin, in: $0) }) ? destination : remap(origin)
            if next != origin, let folder = SessionLinks.folder(for: next) { changed = true; value.sessionLinks.entries[index].folder = folder }
        }
        guard changed else { return nil }
        let locations = value.sessionLinks.entries.map { $0.profileID.uuidString + "/" + $0.folder }
        guard Set(locations).count == locations.count else { throw ModelError.invalid("目标目录已存在此会话的快捷引用，未移动任何项目。") }
        // Preserve empty ordinary source parents, including implicit ancestors.
        value.directories += paths.filter { !SessionLinks.containsDirectory($0) }.map(remap)
        value.sessionLinks.normalize(profiles: value.profiles); value.normalizeSessionLinkDirectories()
        return value
    }
}
