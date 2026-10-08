// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

private final class SessionLinkDragFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { [.move, .link] }
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: .init("OShell.LinksCatalogTest." + UUID().uuidString))
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    deinit { draggingPasteboard.releaseGlobally() }
}

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
        checks["addButtonDisabledWithoutSelection"] = !controller.sessionLinkBar.addButton.isEnabled
        controller.open(first); let source = controller.selectedTab!
        controller.open(second); let selected = controller.selectedTab!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let addRevision = controller.configurationRevision
        controller.sessionLinkBar.addButton.performClick(nil)
        checks["leftButtonDirectlyAddsSelectedSessionToRoot"] = controller.configurationRevision > addRevision && controller.configuration.sessionLinks.entries.contains { $0.profileID == second.id && $0.folder.isEmpty && $0.name == second.name }
        checks["additionNeedsNoModal"] = NSApp.modalWindow == nil
        controller.select(source)
        let duplicateRevision = controller.configurationRevision
        controller.sessionLinkBar.addButton.performClick(nil)
        checks["duplicateRetainsExistingAlias"] = controller.configurationRevision == duplicateRevision && controller.configuration.sessionLinks.entries.first?.name == "开发机"
        checks["leftButtonAddsReferenceWithoutDuplicatingSession"] = controller.configuration.profiles == [first, second] && controller.configuration.sessionLinks.entries.count == 3
        controller.select(selected)
        let strip = descendants(controller.window!.contentView!).compactMap { $0 as? TabStripView }.first!
        let item = strip.items.first { $0.id == source.id }!
        let context = item.selectButton.makeMenu?()
        checks["tabTitleContextUsesClickedTab"] = context?.items.first { $0.title == "添加到快捷链接…" }?.representedObject as? UUID == source.id
        checks["rightClickDoesNotChangeSelection"] = controller.selectedTab === selected
        checks["tabBackgroundHasSameContext"] = item.makeMenu?()?.items.contains { $0.title == "添加到快捷链接…" } == true
        if let entry = context?.items.first(where: { $0.title == "添加到快捷链接…" }) { _ = NSApp.sendAction(entry.action!, to: entry.target, from: entry) }
        checks["realAddActionAvoidsDuplicates"] = controller.configuration.sessionLinks.entries.count == 3 && controller.configuration.sessionLinks.entries.first?.profileID == first.id
        checks["rightClickAddsWithoutModalOrSelectionChange"] = NSApp.modalWindow == nil && controller.selectedTab === selected
        let bar = controller.sessionLinkBar
        checks["rootLinksAndFoldersFlattened"] = Set(bar.buttons.map(\.title)) == Set(["开发机", "运维终端", "运维", "空文件夹"])
        checks["folderHasNestedSession"] = controller.sessionLinkMenu(folder: "运维").items.first?.submenu?.items.first?.title == "运维机"
        let id = controller.configuration.sessionLinks.entries[0].id
        checks["emptyAreaMenuMatchesRequestedActions"] = controller.sessionLinkContextMenu(nil).items.filter { !$0.isSeparatorItem }.map(\.title) == ["添加链接", "新增文件夹", "打开 Links 文件夹", "隐藏链接栏"]
        let beforeDrag = controller.configuration, tabCountBeforeDrag = controller.tabs.count
        func drag(_ source: SessionLinkBar.Target, onto target: SessionLinkBar.Target, fraction: CGFloat) -> SessionLinkDragFixture {
            controller.window?.contentView?.layoutSubtreeIfNeeded(); bar.layoutSubtreeIfNeeded()
            let info = SessionLinkDragFixture()
            info.draggingDestinationWindow = controller.window
            let button = bar.buttons.first { $0.destination == source }!
            let destination = bar.buttons.first { $0.destination == target }!
            info.draggingSource = button
            info.draggingPasteboard.setString(source.key, forType: SessionLinkBar.pasteboardType)
            info.draggingLocation = destination.convert(NSPoint(x: destination.bounds.width * fraction, y: destination.bounds.midY), to: nil)
            return info
        }
        let reorder = drag(.link(id), onto: bar.buttons.first!.destination, fraction: 0.1)
        checks["folderEdgeAcceptsReorder"] = bar.updateDrop(reorder) == .move && bar.performDrop(reorder)
        checks["linkCanPrecedeFolders"] = bar.buttons.first?.destination == .link(id) && controller.configuration.sessionLinks.entries.first?.folder == ""
        checks["toolbarAndOverflowUseSameOrder"] = controller.sessionLinkMenu(folder: "").items.first?.title == "开发机"
        checks["reorderedPositionPersists"] = (try? controller.store.load().sessionLinks.orderedRootItems) == controller.configuration.sessionLinks.orderedRootItems
        let selfDrop = drag(.link(id), onto: .link(id), fraction: 0.1)
        checks["selfDropIsNoOp"] = bar.updateDrop(selfDrop).isEmpty && !bar.performDrop(selfDrop)
        let folderReorder = drag(.folder("运维"), onto: .link(id), fraction: 0.1)
        checks["foldersCanAlsoReorder"] = bar.performDrop(folderReorder) && bar.buttons.first?.destination == .folder("运维")
        let invalid = drag(.link(id), onto: .folder("空文件夹"), fraction: 0.5)
        invalid.draggingPasteboard.setString("link:" + UUID().uuidString, forType: SessionLinkBar.pasteboardType)
        checks["mismatchedPayloadRejected"] = !bar.performDrop(invalid)
        let foreign = drag(.link(id), onto: .folder("空文件夹"), fraction: 0.5)
        foreign.draggingSource = NSObject()
        checks["foreignDragRejected"] = bar.updateDrop(foreign).isEmpty && !bar.performDrop(foreign)
        let intoFolder = drag(.link(id), onto: .folder("空文件夹"), fraction: 0.5)
        checks["folderCenterAcceptsMove"] = bar.updateDrop(intoFolder) == .move && bar.performDrop(intoFolder)
        checks["folderDropMovesOnlyReference"] = controller.configuration.sessionLinks.entries.first { $0.id == id }?.folder == "空文件夹" && controller.configuration.profiles == beforeDrag.profiles
        checks["folderDropUpdatesBarAndMenu"] = !bar.buttons.contains { $0.destination == .link(id) } && controller.sessionLinkMenu(folder: "空文件夹").items.contains { $0.title == "开发机" }
        checks["staleDragRejectedAfterMove"] = !bar.performDrop(intoFolder)
        checks["dragDoesNotOpenOrSelectSessions"] = controller.tabs.count == tabCountBeforeDrag && controller.selectedTab === selected
        checks["folderMovePersists"] = (try? controller.store.load().sessionLinks.entries) == controller.configuration.sessionLinks.entries
        var duplicateTarget = beforeDrag
        duplicateTarget.sessionLinks.add(profileID: first.id, name: "已有引用", folder: "空文件夹")
        _ = controller.saveConfiguration(duplicateTarget)
        let duplicateDrop = drag(.link(id), onto: .folder("空文件夹"), fraction: 0.5)
        let rejectedRevision = controller.configurationRevision
        checks["duplicateInFolderRejectedAtomically"] = bar.updateDrop(duplicateDrop).isEmpty && !bar.performDrop(duplicateDrop) && controller.configurationRevision == rejectedRevision
        _ = controller.saveConfiguration(beforeDrag)
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
        controller.newBlankTab(); let blank = controller.selectedTab!
        checks["blankTabCannotBeMistakenForSavedConnection"] = !bar.addButton.isEnabled
        controller.closeTab(); controller.select(source)
        checks["selectedSessionReenablesAddButton"] = bar.addButton.isEnabled && bar.addButton.image != nil && !controller.tabs.contains { $0 === blank }
        if let group = try? controller.createTabGroup(name: "链接按钮空组") {
            checks["emptyGroupDisablesAddButton"] = !bar.addButton.isEnabled
            controller.select(source); checks["switchingGroupUpdatesAddButton"] = bar.addButton.isEnabled
            controller.dissolveTabGroup(group.id)
        }
        var many = controller.configuration
        for index in 0..<22 {
            var profile = SessionProfile.local; profile.name = "测试会话 \(index)"
            many.profiles.append(profile); many.sessionLinks.add(profileID: profile.id, name: "测试会话 \(index) · 很长的链接名称")
        }
        _ = controller.saveConfiguration(many)
        for width in [760, 1180] {
            controller.window?.setContentSize(NSSize(width: width, height: 600)); controller.window?.contentView?.layoutSubtreeIfNeeded()
            if let scroll = bar.subviews.compactMap({ $0 as? NSScrollView }).first {
                let fixed = bar.addButton.frame
                scroll.contentView.scroll(to: NSPoint(x: max(0, (scroll.documentView?.bounds.width ?? 0) - scroll.contentSize.width), y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
                checks["addButtonFixedBeforeScrollableLinks\(width)"] = bar.addButton.frame == fixed && fixed.minX == 6 && fixed.maxX < scroll.frame.minX && bar.bounds.contains(fixed)
            }
            checks["singleRow\(width)"] = bar.buttons.allSatisfy { $0.frame.minY == 2 && $0.frame.height == 26 && $0.frame.width <= 220 }
            checks["overflowMenu\(width)"] = descendants(bar).compactMap { $0 as? NSPopUpButton }.first?.menu?.items.count == 26
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
