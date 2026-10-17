// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum SessionClipboardTest {
    static func run(_ workspace: WorkspaceController) {
        let start = Timer(timeInterval:0.5,repeats:false) { _ in perform(workspace) }
        RunLoop.main.add(start,forMode:.common)
    }
    private static func perform(_ workspace: WorkspaceController) {
        var checks = [String:Bool]()
        let watchdog = Timer(timeInterval:0.2,repeats:true) { _ in
            guard let alert = NSApp.modalWindow else { return }
            func all(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(all) }
            let labels = all(alert.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
            if labels.contains(where: { $0.hasPrefix("粘贴会话配置失败") || $0.contains("配置已变化") }) {
                FileHandle.standardError.write(Data((labels.joined(separator:" | ")+"\n").utf8))
                _ = PopupKeyboard.dismiss(window:alert)
            }
        }
        RunLoop.main.add(watchdog,forMode:.common); RunLoop.main.add(watchdog,forMode:.modalPanel)
        defer { watchdog.invalidate() }
        let board = NSPasteboard(name:.init("OShell.ClipboardFixture."+UUID().uuidString))
        SessionConfigurationClipboard.pasteboard = board
        defer { SessionConfigurationClipboard.pasteboard = .general; board.releaseGlobally() }
        var a = SessionProfile(name:"node-a",group:"源",host:"192.0.2.10",username:"ops")
        let b = SessionProfile(name:"node-b",group:"源",kind:.sftp,host:"192.0.2.11",username:"deploy")
        let secret = "clipboard-fixture-password"
        do {
            a.encryptedPassword = try PasswordVault.shared.protect(secret,profile:a,knownProfiles:[],protection:.local,identity:SSHIdentity(host:a.host,user:a.username,port:a.port))
            var config = workspace.configuration; config.profiles = [a,b]; config.directories = ["源","目标"]
            checks["fixtureSaved"] = workspace.saveConfiguration(config)
            let manager = SessionManager(workspace:workspace); manager.show(); manager.reveal(a)
            defer { manager.close() }
            let window = manager.window!
            func all(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(all) }
            let table = all(window.contentView!).compactMap { $0 as? NSTableView }.first!
            func key(_ letter:String)->NSEvent {
                NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:letter,charactersIgnoringModifiers:letter,isARepeat:false,keyCode:letter == "c" ? 8 : 9)!
            }
            window.makeFirstResponder(table)
            checks["copyShortcutHandled"] = table.performKeyEquivalent(with:key("c"))
            checks["clipboardOnlyContainsOpaqueToken"] = board.types == [SessionConfigurationClipboard.type] && board.string(forType:.string) == nil && UUID(uuidString:board.string(forType:SessionConfigurationClipboard.type) ?? "") != nil
            checks["wrongStoreCannotPaste"] = SessionConfigurationClipboard.profiles(scope:workspace.store.url.deletingLastPathComponent().appendingPathComponent("other.json")) == nil
            manager.revealDirectory("目标"); window.makeFirstResponder(table)
            let tabs = workspace.tabs.map(\.id)
            checks["pasteShortcutHandled"] = table.performKeyEquivalent(with:key("v"))
            let copied = workspace.configuration.profiles.filter { $0.group == "目标" }
            checks["pastedIntoCurrentDirectory"] = copied.count == 1 && copied[0].name == a.name && copied[0].id != a.id
            if let copy = copied.first {
                checks["passwordReboundAndPreserved"] = try copy.encryptedPassword != a.encryptedPassword && PasswordVault.shared.readSavedPassword(copy) == secret
                checks["connectionOptionsPreserved"] = copy.host == a.host && copy.username == a.username && copy.port == a.port && copy.keepAlive == a.keepAlive
                checks["sourceUnchanged"] = workspace.configuration.profiles.first { $0.id == a.id } == a
                checks["pastedRowSelected"] = manager.selectedProfile?.id == copy.id
            }
            checks["pasteDoesNotConnect"] = tabs == workspace.tabs.map(\.id)
            _ = table.performKeyEquivalent(with:key("v"))
            checks["repeatedPasteGetsUniqueName"] = workspace.configuration.profiles.filter { $0.group == "目标" }.map(\.name).sorted() == ["node-a","node-a - 副本"]
            manager.revealDirectory("源")
            let indexes = (0..<table.numberOfRows).filter { row in
                let cell = manager.tableView(table,viewFor:table.tableColumns[0],row:row) as? NSTableCellView
                return [a.name,b.name].contains(cell?.textField?.stringValue ?? "")
            }
            table.selectRowIndexes(IndexSet(indexes),byExtendingSelection:false)
            manager.copySessionConfigurations()
            checks["multiSelectionCopied"] = SessionConfigurationClipboard.profiles(scope:workspace.store.url)?.count == 2
            // Changes after Copy must not mutate the snapshot.
            var changed = workspace.configuration; changed.profiles[0].name = "changed-later"; _ = workspace.saveConfiguration(changed)
            manager.revealDirectory("Links"); manager.pasteSessionConfigurations()
            checks["batchPastesActualSessionsIntoLinks"] = workspace.configuration.profiles.filter { $0.group == "Links" }.map(\.name).sorted() == [a.name,b.name] && workspace.configuration.sessionLinks.entries.isEmpty
            checks["batchSelected"] = manager.selectedProfiles.count == 2
            let reload = try workspace.store.load()
            checks["diskMatchesSavedBatch"] = reload.profiles == workspace.configuration.profiles
            let before = workspace.configuration.profiles.count
            board.clearContents(); board.setString("ordinary text",forType:.string)
            manager.pasteSessionConfigurations()
            checks["plainTextDoesNotCreateSession"] = workspace.configuration.profiles.count == before
            checks["replacedClipboardDisablesPaste"] = !manager.contextMenu(for:-1).items.contains { $0.title == "粘贴会话配置" && $0.isEnabled }
            manager.revealDirectory("")
            table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
            checks["directoriesCannotBeCopiedAsSessions"] = !manager.contextMenu(for:0).items.contains { $0.title == "复制会话配置" && $0.isEnabled }
            let search = all(window.contentView!).compactMap { $0 as? NSSearchField }.first!
            window.makeFirstResponder(search); search.selectText(nil)
            checks["textEditingNotIntercepted"] = !table.performKeyEquivalent(with:key("c")) && !table.performKeyEquivalent(with:key("v"))
        } catch { checks["unexpectedError"] = false }
        let result:[String:Any] = ["passed":checks.values.allSatisfy { $0 },"checks":checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_SESSION_CLIPBOARD_OUTPUT"] { try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path)) }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
