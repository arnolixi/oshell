// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

private final class SessionDirectoryDragFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: .init("OShell.SessionDirectoryTest." + UUID().uuidString))
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

enum SessionDirectoryTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] {
            let children = (view as? NSTabView)?.tabViewItems.compactMap(\.view) ?? view.subviews
            return [view] + children.flatMap(descendants)
        }
        func nextModal(_ body: @escaping (NSView) -> Void) {
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in if let root = NSApp.modalWindow?.contentView { body(root) } }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
        }
        func press(_ root: NSView, _ title: String) { descendants(root).compactMap { $0 as? NSButton }.first { $0.title == title }?.performClick(nil) }
        let a = SessionProfile(name: "node-a", group: "", host: "a.example.test")
        let b = SessionProfile(name: "node-b", group: "", kind: .ftp, host: "b.example.test", port: 21)
        let nested = SessionProfile(name: "nested", group: "源目录/内部", host: "nested.example.test")
        var config = workspace.configuration; config.profiles = [a, b, nested]; config.directories = ["源目录/空目录", "目标目录/另一层"]
        checks["fixtureSaved"] = workspace.saveConfiguration(config)
        let manager = SessionManager(workspace: workspace)
        let table = descendants(manager.window!.contentView!).compactMap { $0 as? NSTableView }.first!
        func row(_ name: String) -> Int {
            (0..<table.numberOfRows).first { (manager.tableView(table, viewFor: table.tableColumns[0], row: $0) as? NSTableCellView)?.textField?.stringValue == name } ?? -1
        }
        func drag(_ indexes: [Int]) -> SessionDirectoryDragFixture {
            let info = SessionDirectoryDragFixture(); info.draggingSource = table; info.draggingDestinationWindow = manager.window
            let items = indexes.compactMap { manager.tableView(table, pasteboardWriterForRow: $0) }
            info.draggingPasteboard.writeObjects(items); return info
        }
        let multi = drag([row(a.name), row(b.name)])
        let target = row("源目录")
        checks["multiDropAccepted"] = manager.tableView(table, validateDrop: multi, proposedRow: target, proposedDropOperation: .on) == .move
        checks["dropOnSessionRejected"] = manager.tableView(table, validateDrop: multi, proposedRow: row(a.name), proposedDropOperation: .on).isEmpty
        multi.draggingSource = NSView()
        checks["externalDragRejected"] = manager.tableView(table, validateDrop: multi, proposedRow: target, proposedDropOperation: .on).isEmpty
        multi.draggingSource = table
        checks["multiDropSaved"] = manager.tableView(table, acceptDrop: multi, row: target, dropOperation: .on)
        checks["bothSessionsMoved"] = workspace.configuration.profiles.prefix(2).allSatisfy { $0.group == "源目录" }
        checks["protocolPreserved"] = workspace.configuration.profiles[1].kind == .ftp
        checks["diskSaved"] = (try? workspace.store.load().profiles) == workspace.configuration.profiles
        manager.reveal(workspace.configuration.profiles[0])
        checks["parentNotDraggable"] = manager.tableView(table, pasteboardWriterForRow: 0) == nil
        let toParent = drag([row(a.name), row(b.name)])
        checks["dropOnParent"] = manager.tableView(table, acceptDrop: toParent, row: 0, dropOperation: .on)
        checks["parentMovesToRoot"] = workspace.configuration.profiles.prefix(2).allSatisfy { $0.group.isEmpty }
        manager.reveal(a)
        let folder = drag([row("源目录")])
        checks["folderCannotDropOntoItself"] = manager.tableView(table, validateDrop: folder, proposedRow: row("源目录"), proposedDropOperation: .on).isEmpty
        checks["folderDropSaved"] = manager.tableView(table, acceptDrop: folder, row: row("目标目录"), dropOperation: .on)
        checks["folderPreservesSubtree"] = workspace.configuration.profiles[2].group == "目标目录/源目录/内部" && workspace.configuration.directories.contains("目标目录/源目录/空目录")
        // Reusing a drag after its source folder moved must not touch another row.
        checks["staleFolderDropRejected"] = manager.tableView(table, validateDrop: folder, proposedRow: row("目标目录"), proposedDropOperation: .on).isEmpty

        manager.reveal(workspace.configuration.profiles[2])
        let revision = workspace.configurationRevision
        nextModal { root in
            let input = descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "session.directory.name" }!
            checks["newDirectoryOnlyShowsName"] = input.stringValue == "新目录"
            input.stringValue = "新子目录"; press(root, "确定")
        }
        let newItem = manager.contextMenu(for: -1).items.first { $0.title == "新建目录…" }!
        _ = NSApp.sendAction(newItem.action!, to: newItem.target, from: newItem)
        checks["newDirectoryIsDirectChild"] = workspace.configuration.directories.contains("目标目录/源目录/内部/新子目录") && manager.currentDirectory == "目标目录/源目录/内部"
        checks["createSavedOnce"] = workspace.configurationRevision == revision + 1
        nextModal { root in press(root, "取消") }
        _ = NSApp.sendAction(newItem.action!, to: newItem.target, from: newItem)
        checks["cancelCreateDoesNotSave"] = workspace.configurationRevision == revision + 1

        let editor = SessionEditor(a, profiles: config.profiles, directories: SessionDirectory.all(workspace.configuration), initialDirectory: "")
        let picker = descendants(editor.dialog.accessoryView!).compactMap { $0 as? SessionDirectoryPicker }.first!
        checks["fieldIsNotEditableText"] = !descendants(editor.dialog.accessoryView!).contains { $0 is NSComboBox }
        nextModal { root in
            let tree = descendants(root).compactMap { $0 as? SessionDirectoryTree }.first!
            checks["treeInitiallySelectsRoot"] = tree.selectedDirectory == ""
            checks["treeCanSelectNestedDirectory"] = tree.selectDirectory("目标目录/源目录/内部/新子目录")
            checks["treeRejectsUnknownPath"] = !tree.selectDirectory("不存在")
            if let path = ProcessInfo.processInfo.environment["OSHELL_DIRECTORY_PREVIEW"], let bitmap = tree.bitmapImageRepForCachingDisplay(in: tree.bounds) {
                tree.layoutSubtreeIfNeeded(); tree.cacheDisplay(in: tree.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            press(root, "选择")
        }
        picker.performClick(nil)
        checks["pickerReflectsSelection"] = picker.selectedDirectory == "目标目录/源目录/内部/新子目录"
        nextModal { root in
            let tree = descendants(root).compactMap { $0 as? SessionDirectoryTree }.first!
            _ = tree.selectDirectory(""); if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
        }
        picker.performClick(nil)
        checks["escapeKeepsPreviousSelection"] = picker.selectedDirectory == "目标目录/源目录/内部/新子目录"
        nextModal { root in
            nextModal { _ in if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
            picker.performClick(nil)
            checks["escapeOnlyClosesNestedDirectoryPicker"] = NSApp.modalWindow === editor.dialog.window
            press(root, "保存")
        }
        let edited = editor.run()
        checks["editorSavesTreeSelection"] = edited?.group == picker.selectedDirectory && edited?.id == a.id && edited?.host == a.host
        let restricted = SessionDirectoryTree(directories: SessionDirectory.all(workspace.configuration), selected: "", excluded: ["目标目录/源目录"])
        checks["movingTreeDisablesOwnDescendants"] = !restricted.selectDirectory("目标目录/源目录/内部") && restricted.selectDirectory("目标目录")

        manager.reveal(a); table.selectRowIndexes(IndexSet([row(a.name), row(b.name)]), byExtendingSelection: false)
        let move = manager.contextMenu(for: row(a.name)).items.first { $0.title == "移动到…" }!
        nextModal { root in
            let tree = descendants(root).compactMap { $0 as? SessionDirectoryTree }.first!
            _ = tree.selectDirectory("目标目录"); press(root, "选择")
        }
        _ = NSApp.sendAction(move.action!, to: move.target, from: move)
        checks["multiContextMoveUsesTree"] = workspace.configuration.profiles.prefix(2).allSatisfy { $0.group == "目标目录" }
        // Delete through the real context menu, including cancellation and disk state.
        var disposable = SessionProfile.local; disposable.name = "待删本地配置"; disposable.group = "删除测试/含会话/下级"
        var removal = workspace.configuration; removal.profiles.append(disposable)
        removal.directories += ["删除测试/空目录", "删除测试/含会话/空子目录", "删除测试/含会话保留"]
        removal.sessionLinks.add(profileID: disposable.id, name: "引用待删会话", folder: "删除测试引用")
        _ = workspace.saveConfiguration(removal)
        workspace.open(disposable); let live = workspace.selectedTab!, livePane = live.activePane
        manager.revealDirectory("删除测试")
        func removeRow(_ title: String) {
            let item = manager.contextMenu(for: row(title)).items.first { $0.title == "删除…" }!
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        let emptyRevision = workspace.configurationRevision
        removeRow("空目录")
        checks["emptyDirectoryDeletesWithoutConfirmation"] = workspace.configurationRevision == emptyRevision + 1 && !SessionDirectory.all(workspace.configuration).contains("删除测试/空目录") && NSApp.modalWindow == nil
        let beforeCancel = workspace.configurationRevision
        nextModal { root in
            let text = descendants(root).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: " ")
            checks["nonemptyDirectoryShowsRecursiveCounts"] = text.contains("2 个子目录") && text.contains("1 个会话配置") && text.contains("1 个快捷引用")
            if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
        }
        removeRow("含会话")
        checks["cancelRecursiveDeletionChangesNothing"] = workspace.configurationRevision == beforeCancel && workspace.configuration.profiles.contains { $0.id == disposable.id }
        nextModal { root in press(root, "递归删除") }
        removeRow("含会话")
        checks["confirmedDirectoryDeletionIsRecursive"] = !SessionDirectory.all(workspace.configuration).contains { SessionDirectory.contains($0, in: "删除测试/含会话") } && !workspace.configuration.profiles.contains { $0.id == disposable.id }
        checks["directoryDeletionKeepsSimilarNamedSibling"] = SessionDirectory.all(workspace.configuration).contains("删除测试/含会话保留")
        checks["directoryDeletionRemovesDanglingLinks"] = !workspace.configuration.sessionLinks.entries.contains { $0.profileID == disposable.id }
        checks["directoryDeletionDoesNotCloseLiveTab"] = workspace.tabs.contains { $0 === live } && live.activePane === livePane && !livePane.isShutdown
        checks["directoryDeletionPersistsAfterReload"] = (try? workspace.store.load().profiles.contains { $0.id == disposable.id }) == false && (try? workspace.store.load().directories.contains("删除测试/含会话/空子目录")) == false
        manager.revealDirectory("")
        checks["linksRootDeleteDisabled"] = manager.contextMenu(for: row("Links")).items.first { $0.title == "删除…" }?.isEnabled == false
        // Batch deletion uses the real selection/context menu and one save.
        let batchA = SessionProfile(name: "batch-a", group: "批量测试", kind: .local)
        let batchB = SessionProfile(name: "batch-b", group: "批量测试", kind: .ftp, host: "batch.example.test", port: 21)
        let keep = SessionProfile(name: "keep", group: "批量测试", host: "keep.example.test")
        var batch = workspace.configuration; batch.profiles += [batchA, batchB, keep]
        batch.sessionLinks.add(profileID: batchA.id, name: "外部引用", folder: "批量引用")
        _ = workspace.saveConfiguration(batch)
        workspace.open(batchA); let batchLive = workspace.selectedTab!.activePane
        manager.reveal(batchA)
        func batchMenu(_ names: [String]) -> NSMenuItem {
            let indexes = names.map(row)
            table.selectRowIndexes(IndexSet(indexes), byExtendingSelection: false)
            return manager.contextMenu(for: indexes[0]).items.first { $0.title.hasPrefix("删除所选") }!
        }
        func invoke(_ item: NSMenuItem) { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
        let beforeBatch = workspace.configurationRevision
        let deleteBatch = batchMenu([batchA.name, batchB.name])
        checks["batchDeleteMenuPreservesSelection"] = deleteBatch.isEnabled && table.selectedRowIndexes.count == 2 && deleteBatch.title.contains("2")
        nextModal { root in
            let text = descendants(root).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: " ")
            checks["batchConfirmationShowsImpact"] = text.contains("2 个会话配置") && text.contains("1 个快捷引用") && text.contains(batchA.name) && text.contains(batchB.name)
            if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
        }
        invoke(deleteBatch)
        checks["cancelBatchLeavesConfiguration"] = workspace.configurationRevision == beforeBatch && workspace.configuration.profiles.contains { $0.id == batchA.id }
        nextModal { root in press(root, "删除所选") }
        invoke(deleteBatch)
        checks["batchDeletesOnce"] = workspace.configurationRevision == beforeBatch + 1 && !workspace.configuration.profiles.contains { [batchA.id, batchB.id].contains($0.id) }
        checks["batchKeepsUnselectedAndDirectory"] = workspace.configuration.profiles.contains { $0.id == keep.id } && SessionDirectory.all(workspace.configuration).contains("批量测试")
        checks["batchRemovesExternalReferences"] = !workspace.configuration.sessionLinks.entries.contains { $0.profileID == batchA.id }
        checks["batchLeavesLiveSessionRunning"] = !batchLive.isShutdown && workspace.tabs.contains { $0.layout.panes.contains { $0 === batchLive } }
        checks["batchPersistsOnDisk"] = (try? workspace.store.load().profiles.contains { [batchA.id, batchB.id].contains($0.id) }) == false

        var links = workspace.configuration
        links.sessionLinks.add(profileID: keep.id, name: "批量引用一", folder: "批量引用")
        links.sessionLinks.add(profileID: keep.id, name: "批量引用二", folder: "批量引用/子目录")
        _ = workspace.saveConfiguration(links)
        manager.revealDirectory(SessionLinks.directory(for: "批量引用"))
        let mixed = batchMenu(["批量引用一", "子目录"])
        nextModal { root in press(root, "删除所选") }; invoke(mixed)
        checks["mixedFolderAndReferenceDeleteKeepsSource"] = workspace.configuration.profiles.contains { $0.id == keep.id } && !workspace.configuration.sessionLinks.entries.contains { $0.name.hasPrefix("批量引用") }
        checks["mixedDeleteRecursesAndKeepsParent"] = !SessionDirectory.all(workspace.configuration).contains(SessionLinks.directory(for: "批量引用/子目录")) && SessionDirectory.all(workspace.configuration).contains(SessionLinks.directory(for: "批量引用"))
        manager.revealDirectory("")
        checks["batchProtectsLinksRoot"] = !batchMenu(["Links", "批量测试"]).isEnabled
        manager.reveal(keep)
        checks["batchProtectsParentRow"] = !batchMenu(["../", keep.name]).isEnabled
        var changed = workspace.configuration; changed.profiles += [batchA, batchB]; _ = workspace.saveConfiguration(changed)
        manager.reveal(batchA)
        let stale = batchMenu([batchA.name, batchB.name])
        nextModal { root in
            var concurrent = workspace.configuration; concurrent.profiles.append(SessionProfile(name: "concurrent", host: "concurrent.example.test"))
            _ = workspace.saveConfiguration(concurrent)
            nextModal { _ in if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
            press(root, "删除所选")
        }
        invoke(stale)
        checks["batchRejectsStaleConfirmation"] = workspace.configuration.profiles.contains { $0.id == batchA.id } && workspace.configuration.profiles.contains { $0.name == "concurrent" }
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_DIRECTORY_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        print("Directory checks: \(checks.count), failed: \(checks.filter { !$0.value }.keys.sorted())")
        manager.close(); workspace.shutdown(); NSApp.terminate(nil)
    }
}
