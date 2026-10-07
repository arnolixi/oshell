// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum SessionLinksTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool]()
        var first = SessionProfile.local; first.name = "开发终端"
        var second = SessionProfile.local; second.name = "运维终端"
        var config = controller.configuration; config.preferences.metal = false
        config.profiles = [first, second]
        config.sessionLinks.add(profileID: first.id, name: "开发机")
        config.sessionLinks.add(profileID: second.id, name: "运维机", folder: "运维/内网")
        config.sessionLinks.folders.append("空文件夹")
        checks["saveConfiguration"] = controller.saveConfiguration(config)
        controller.open(first); let source = controller.selectedTab!
        controller.open(second); let selected = controller.selectedTab!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let strip = descendants(controller.window!.contentView!).compactMap { $0 as? TabStripView }.first!
        let item = strip.items.first { $0.id == source.id }!
        let context = item.selectButton.makeMenu?()
        checks["tabTitleContextUsesClickedTab"] = context?.items.first?.representedObject as? UUID == source.id
        checks["rightClickDoesNotChangeSelection"] = controller.selectedTab === selected
        checks["tabBackgroundHasSameContext"] = item.makeMenu?()?.items.first?.title == "添加到快捷链接…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let root = NSApp.modalWindow?.contentView else { return }
            let fields = descendants(root).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            checks["addDialogUsesClickedProfile"] = fields.first?.stringValue == first.name
            fields.first?.stringValue = "开发机"
            descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "添加" }?.performClick(nil)
        }
        if let entry = context?.items.first { _ = NSApp.sendAction(entry.action!, to: entry.target, from: entry) }
        checks["realAddActionAvoidsDuplicates"] = controller.configuration.sessionLinks.entries.count == 2 && controller.configuration.sessionLinks.entries.first?.profileID == first.id
        let revision = controller.configurationRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
        controller.addSessionLink(tabID: source.id)
        checks["escapeCancelsWithoutSaving"] = controller.configurationRevision == revision
        let bar = controller.sessionLinkBar
        checks["rootLinksAndFoldersFlattened"] = Set(bar.buttons.map(\.title)) == Set(["开发机", "运维", "空文件夹"])
        checks["folderHasNestedSession"] = controller.sessionLinkMenu(folder: "运维").items.first?.submenu?.items.first?.title == "运维机"
        let id = controller.configuration.sessionLinks.entries[0].id
        let originalCount = controller.tabs.count
        bar.buttons.first { $0.destination == .link(id) }?.performClick(nil)
        checks["buttonOpensNewSession"] = controller.tabs.count == originalCount + 1 && controller.selectedTab?.activePane.profile.id == first.id
        // Links resolve fresh configuration, not the old pane's connection snapshot.
        var updated = controller.configuration; updated.profiles[0].name = "更新后的配置"
        checks["saveUpdatedProfile"] = controller.saveConfiguration(updated)
        controller.openSessionLink(id)
        checks["linkUsesLatestProfile"] = controller.selectedTab?.activePane.profile.name == "更新后的配置"
        let move = controller.sessionLinkContextMenu(.link(id)).items.first { $0.title == "移动到" }?.submenu?.items.first { $0.title == "运维/内网" }
        if let move, let action = move.action { _ = NSApp.sendAction(action, to: move.target, from: move) }
        checks["moveLinkToFolder"] = controller.configuration.sessionLinks.entries.first { $0.id == id }?.folder == "运维/内网" && !bar.buttons.contains { $0.destination == .link(id) }
        checks["folderLinksHaveManagementActions"] = controller.sessionLinkContextMenu(.folder("运维")).items.contains { $0.title == "管理链接" }
        controller.toggleSessionLinkBar()
        checks["hideReturnsTerminalSpace"] = bar.isHidden && controller.sessionLinkHeight.constant == 0
        checks["hiddenStatePersists"] = (try? controller.store.load().sessionLinks.visible) == false
        controller.toggleSessionLinkBar()
        checks["showRestoresBar"] = !bar.isHidden && controller.sessionLinkHeight.constant == 30
        var many = controller.configuration
        for index in 0..<22 {
            var profile = SessionProfile.local; profile.name = "测试会话 \(index)"
            many.profiles.append(profile); many.sessionLinks.add(profileID: profile.id, name: "测试会话 \(index) · 很长的链接名称")
        }
        _ = controller.saveConfiguration(many)
        for width in [760, 1180] {
            controller.window?.setContentSize(NSSize(width: width, height: 600)); controller.window?.contentView?.layoutSubtreeIfNeeded()
            checks["singleRow\(width)"] = bar.buttons.allSatisfy { $0.frame.minY == 2 && $0.frame.height == 26 && $0.frame.width <= 220 }
            checks["overflowMenu\(width)"] = descendants(bar).compactMap { $0 as? NSPopUpButton }.first?.menu?.items.count == 25
            let root = controller.window!.contentView!
            let linkFrame = bar.convert(bar.bounds, to: root), tabFrame = strip.convert(strip.bounds, to: root)
            checks["barAboveTabs\(width)"] = linkFrame.minY >= tabFrame.maxY && root.bounds.contains(linkFrame)
        }
        let remove = controller.sessionLinkContextMenu(.link(id)).items.first { $0.title == "从快捷链接移除" }!
        _ = NSApp.sendAction(remove.action!, to: remove.target, from: remove)
        checks["removingLinkKeepsProfile"] = controller.configuration.profiles.contains { $0.id == first.id } && !controller.configuration.sessionLinks.entries.contains { $0.id == id }
        var deleted = controller.configuration; deleted.profiles.removeAll { $0.id == second.id }; _ = controller.saveConfiguration(deleted)
        checks["deletedProfilesRemoveStaleLinks"] = !controller.configuration.sessionLinks.entries.contains { $0.profileID == second.id }
        checks["restartPreservesLinks"] = (try? controller.store.load().sessionLinks.entries) == controller.configuration.sessionLinks.entries
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_SESSION_LINKS_OUTPUT"] {
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print(report); controller.shutdown(); NSApp.terminate(nil)
    }
}
