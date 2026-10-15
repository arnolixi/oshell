// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

/// Exercises the real table field editor against an isolated configuration.
enum SessionInlineRenameTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String:Bool]()
        func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
        var source = SessionProfile(name:"原会话",group:"生产/子目录",host:"node.example.test",username:"fixture")
        let secret = "inline-rename-fixture"
        do { source.encryptedPassword = try PasswordVault.shared.protect(secret,profile:source,knownProfiles:[],protection:.local,identity:SSHIdentity(host:source.host,user:source.username,port:source.port)) }
        catch { checks["passwordFixture"] = false }
        var other = SessionProfile(name:"另一会话",group:"",host:"other.example.test",username:"fixture")
        var local = SessionProfile.local; local.name = "本地"; local.group = ""
        var actual = source; actual.id = UUID(); actual.name = "实际会话"; actual.group = "Links/运维/子目录"; actual.encryptedPassword = nil
        var config = workspace.configuration; config.profiles = [source,other,local,actual]
        config.directories = ["生产/子目录/空目录","冲突目录"]
        config.sessionLinks.add(profileID:source.id,name:"快捷别名",folder:"运维/子目录")
        checks["fixtureSaved"] = workspace.saveConfiguration(config)
        let linkID = workspace.configuration.sessionLinks.entries.first!.id
        workspace.newLocal()
        let pane = workspace.selectedTab!.activePane, pid = workspace.selectedTab!.activePane.terminal.process.shellPid
        workspace.showSessionManager()
        let manager = NSApp.windows.compactMap { $0.windowController as? SessionManager }.first!
        let window = manager.window!, root = window.contentView!
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let table = descendants(root).compactMap { $0 as? NSTableView }.first!
        let search = descendants(root).compactMap { $0 as? NSSearchField }.first!
        func row(_ name:String)->Int { (0..<table.numberOfRows).first { (manager.tableView(table,viewFor:table.tableColumns[0],row:$0) as? NSTableCellView)?.textField?.stringValue == name } ?? -1 }
        func select(_ name:String) { let index = row(name); if index >= 0 { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) } }
        func field()->NSTextField? { descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "session.inlineName" } }
        func type(_ text:String) { field()?.stringValue = text; (field()?.currentEditor() as? NSTextView)?.string = text }
        func rename(_ text:String)->Bool { manager.beginInlineRename(); type(text); return manager.commitInlineRename() }
        func editButton(_ index:Int)->NSButton? {
            guard index >= 0, let column = table.tableColumns.first(where: { $0.identifier.rawValue == "edit" }), let cell = manager.tableView(table,viewFor:column,row:index) else { return nil }
            return cell.subviews.first as? NSButton
        }
        manager.reveal(source); window.makeFirstResponder(table)
        let f2 = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:120)!
        table.keyDown(with:f2)
        checks["F2StartsInlineWithoutPopup"] = field()?.currentEditor() != nil && NSApp.modalWindow == nil
        type("新的会话名称")
        let count = workspace.tabs.count
        if let field = field(), let editor = field.currentEditor() as? NSTextView {
            checks["ReturnConsumed"] = manager.control(field,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:)))
        } else { checks["ReturnConsumed"] = false }
        var expected = source; expected.name = "新的会话名称"
        checks["OnlySessionNameChanged"] = workspace.configuration.profiles.first { $0.id == source.id } == expected
        checks["PasswordStillDecrypts"] = (try? PasswordVault.shared.readSavedPassword(expected)) == secret
        checks["RenameDoesNotConnect"] = workspace.tabs.count == count && NSApp.modalWindow == nil
        checks["SelectionFollowsRenamedUUID"] = manager.selectedProfile?.id == source.id
        manager.beginInlineRename(); type("取消改名")
        checks["EscapeCancelsWithoutClosing"] = PopupKeyboard.dismiss(window:window) && window.isVisible && field() == nil && workspace.configuration.profiles.contains(expected)
        manager.beginInlineRename(); type("失焦取消"); window.makeFirstResponder(search)
        checks["BlurCancels"] = field() == nil && workspace.configuration.profiles.contains(expected)
        manager.reveal(expected); manager.beginInlineRename()
        for (key,text) in [("Empty","   "),("Control","name\nline")] { type(text); checks["Reject"+key] = !manager.commitInlineRename() && field() != nil }
        type("再次改名"); checks["ValidAfterError"] = manager.commitInlineRename()
        expected.name = "再次改名"
        manager.beginInlineRename(); type("刷新丢弃"); manager.reload()
        checks["ReloadCancelsEditor"] = field() == nil && workspace.configuration.profiles.contains(expected)
        manager.revealDirectory(""); select("生产")
        checks["DirectoryNoPencil"] = editButton(row("生产"))?.isHidden == true
        manager.beginInlineRename(); type("冲突目录")
        checks["DirectoryCollisionRejected"] = !manager.commitInlineRename() && field() != nil
        type("坏/目录"); checks["DirectoryPathRejected"] = !manager.commitInlineRename()
        type("生产新"); checks["DirectorySaved"] = manager.commitInlineRename()
        expected.group = "生产新/子目录"
        checks["DirectorySubtreeRemapped"] = workspace.configuration.profiles.contains(expected) && SessionDirectory.all(workspace.configuration).contains("生产新/子目录/空目录") && !SessionDirectory.all(workspace.configuration).contains("生产")
        checks["DirectorySelectionFollowsName"] = table.selectedRow == row("生产新")
        select("Links"); manager.beginInlineRename(); checks["ReservedRootNotEditable"] = field() == nil
        manager.revealDirectory("生产新"); select("../"); manager.beginInlineRename()
        checks["ParentNotEditableOrPencilled"] = field() == nil && editButton(row("../"))?.isHidden == true
        manager.revealDirectory("Links"); select("运维")
        checks["LinksFolderRenamedInline"] = rename("运维新")
        actual.group = "Links/运维新/子目录"
        checks["LinksRemapsActualAndAlias"] = workspace.configuration.profiles.contains(actual) && workspace.configuration.sessionLinks.entries.first?.folder == "运维新/子目录"
        checks["LinksLeavesSourceAlone"] = workspace.configuration.profiles.contains(expected)
        manager.revealLink(linkID)
        checks["LinkPencilPresent"] = editButton(table.selectedRow)?.isHidden == false
        checks["AliasRenamedInline"] = rename("新快捷名") && workspace.configuration.sessionLinks.entries.first?.name == "新快捷名"
        checks["AliasDoesNotRenameSource"] = workspace.configuration.profiles.contains(expected)
        manager.reveal(other); manager.beginInlineRename(); type("过期草稿")
        let index = workspace.configuration.profiles.firstIndex { $0.id == other.id }!
        workspace.configuration.profiles[index].name = "外部修改"
        checks["StaleNameNotOverwritten"] = !manager.commitInlineRename() && workspace.configuration.profiles[index].name == "外部修改"
        manager.cancelInlineRename(); other.name = "外部修改"
        _ = workspace.saveConfiguration(workspace.configuration)
        manager.reveal(local)
        let button = editButton(row(other.name))
        checks["SessionPencilPresent"] = button?.isHidden == false && button?.isEnabled == true
        var openedCorrect = false
        let timer = Timer(timeInterval:0.05,repeats:false) { _ in
            guard let modal = NSApp.modalWindow else { return }
            let fields = descendants(modal.contentView!).compactMap { $0 as? NSTextField }
            openedCorrect = fields.first { $0.identifier?.rawValue == "session.name" }?.stringValue == other.name
            _ = PopupKeyboard.dismiss(window:modal)
        }
        RunLoop.main.add(timer,forMode:.common); RunLoop.main.add(timer,forMode:.init("NSModalPanelRunLoopMode"))
        if button != nil { button?.performClick(nil) } else { timer.invalidate() }
        checks["PencilEditsClickedRowNotSelection"] = openedCorrect
        manager.reveal(local); editButton(table.selectedRow)?.performClick(nil)
        checks["LocalPencilStartsRename"] = field() != nil
        manager.cancelInlineRename()
        table.selectRowIndexes(IndexSet(integersIn:0..<min(2,table.numberOfRows)),byExtendingSelection:false)
        manager.beginInlineRename(); checks["MultiSelectionNotRenamed"] = field() == nil
        checks["EditColumnStaysLast"] = !manager.tableView(table,shouldReorderColumn:table.numberOfColumns-1,toColumn:0) && !manager.tableView(table,shouldReorderColumn:0,toColumn:table.numberOfColumns-1)
        checks["ExistingTerminalPreserved"] = workspace.selectedTab?.activePane === pane && pane.terminal.process.shellPid == pid && pid > 0
        checks["SavedRenameRoundTrips"] = (try? workspace.store.load().profiles.first { $0.id == source.id }) == expected
        manager.reveal(expected); manager.beginInlineRename(); type("截图预览名称")
        root.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["OSHELL_SESSION_INLINE_RENAME_OUTPUT"] {
            if let bitmap = root.bitmapImageRepForCachingDisplay(in:root.bounds) { root.cacheDisplay(in:root.bounds,to:bitmap); try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).deletingPathExtension().appendingPathExtension("png")) }
            let report:[String:Any] = ["passed":checks.values.allSatisfy { $0 },"checks":checks]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        }
        manager.close(); workspace.shutdown(); NSApp.terminate(nil)
    }
}
