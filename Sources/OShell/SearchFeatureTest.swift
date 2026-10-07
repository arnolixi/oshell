// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import SwiftTerm
import OShellCore

enum SearchFeatureTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var preferences = Preferences(); preferences.metal = false
        let pane = TerminalPane(profile: .local, preferences: preferences, knownHostsFile: controller.store.url.deletingLastPathComponent().appendingPathComponent("known_hosts"))
        let terminal = pane.terminal, panel = pane.searchPanel
        let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false; previewWindow.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        func feed(_ text: String, columns: Int = 80) {
            terminal.clearSearch(); terminal.getTerminal().resetToInitialState()
            terminal.getTerminal().resize(cols: columns, rows: 12)
            terminal.feed(text: text)
        }
        func selected() -> String { terminal.selection.getSelectedText() }
        func capture(_ view: NSView, name: String) {
            guard let path = ProcessInfo.processInfo.environment["OSHELL_SEARCH_PREVIEW_DIR"] else { return }
            // Layer-backed native controls need a window-server surface for a
            // complete preview. Do not activate the application or take focus.
            view.window?.orderFront(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let preview = NSImage(size: view.bounds.size); preview.lockFocus()
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill()
            bitmap.draw(in: view.bounds); preview.unlockFocus()
            if let tiff = preview.tiffRepresentation {
                try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
            }
            view.window?.orderOut(nil)
        }
        feed("concatenate cat bobcat cat\r\n")
        let words = SearchOptions(wholeWord: true)
        checks["wholeWordSkipsEarlierPartial"] = terminal.findNext("cat", options: words) && terminal.selection.start.col == 12
        checks["wholeWordCount"] = terminal.searchMatchSummary("cat", options: words).total == 2
        _ = terminal.findNext("cat", options: words)
        checks["nextMatchPosition"] = terminal.selection.start.col == 23
        _ = terminal.findNext("cat", options: words)
        checks["nextWraps"] = terminal.selection.start.col == 12
        _ = terminal.findPrevious("cat", options: words)
        checks["previousWraps"] = terminal.selection.start.col == 23
        _ = terminal.findPrevious("cat", options: words)
        checks["previousSkipsPartial"] = terminal.selection.start.col == 12
        feed("cat cat\r\ndog cat\r\n")
        let regex = SearchOptions(regex: true)
        _ = terminal.findNext("^cat", options: regex); _ = terminal.findNext("^cat", options: regex)
        checks["regexAnchorsStayAtLogicalLineStart"] = terminal.selection.start.col == 0 && terminal.selection.start.row == 0 && terminal.searchMatchSummary("^cat", options: regex).total == 1
        feed("dog cat\r\n")
        checks["zeroWidthAlternativeDoesNotHideMatch"] = terminal.findNext("^|cat", options: regex) && selected() == "cat"
        checks["onlyZeroWidthDoesNotLoop"] = !terminal.findNext("(?=cat)", options: regex) && terminal.searchMatchSummary("(?=cat)", options: regex).total == 0
        checks["invalidRegexHasMessage"] = !terminal.findNext("[", options: regex) && terminal.searchIssue?.contains("正则表达式无效") == true
        feed("中文 😀 苹果 e\u{301} tail\r\n")
        checks["wideChineseSelection"] = terminal.findNext("苹果") && selected() == "苹果"
        checks["emojiSelection"] = terminal.findNext("😀") && selected() == "😀"
        checks["combiningMarkSelectsWholeCell"] = terminal.findNext("e", options: regex) && selected() == "e\u{301}"
        feed("123456789中 cat 中 cat", columns: 10)
        checks["softWrapSearch"] = terminal.findNext("中 cat") && selected().replacingOccurrences(of: "\n", with: "") == "中 cat"
        checks["wideWrapCount"] = terminal.searchMatchSummary("中 cat").total == 2
        _ = terminal.findNext("中 cat"); let second = terminal.selection.start
        _ = terminal.findPrevious("中 cat"); let first = terminal.selection.start
        checks["wideWrapNavigation"] = second != first && selected().replacingOccurrences(of: "\n", with: "") == "中 cat"
        feed("Error error ERROR\r\n")
        checks["caseInsensitiveCount"] = terminal.searchMatchSummary("error").total == 3
        checks["caseSensitiveCount"] = terminal.searchMatchSummary("error", options: SearchOptions(caseSensitive: true)).total == 1
        terminal.feed(text: "error\r\n")
        checks["outputInvalidatesCachedCount"] = terminal.searchMatchSummary("error").total == 4
        feed("history-only\r\n" + String(repeating: "line\r\n", count: 25))
        checks["retainedHistoryIsSearchable"] = terminal.searchMatchSummary("history-only").total == 1
        terminal.clearScrollback()
        checks["clearHistoryInvalidatesCachedCount"] = terminal.searchMatchSummary("history-only").total == 0
        feed("history-only\r\n" + String(repeating: "line\r\n", count: 25))
        _ = terminal.searchMatchSummary("history-only")
        terminal.changeScrollback(0)
        checks["shrinkHistoryInvalidatesCachedCount"] = terminal.searchMatchSummary("history-only").total == 0
        terminal.changeScrollback(preferences.scrollback)
        feed(String(repeating: "a", count: 8000) + "!", columns: 10000)
        let start = ProcessInfo.processInfo.systemUptime
        _ = terminal.findNext("(a+)+$", options: regex)
        checks["expensiveRegexBounded"] = ProcessInfo.processInfo.systemUptime - start < 2 && terminal.searchIssue != nil
        feed(String(repeating: "hit ", count: 1200), columns: 100)
        panel.show(prefillSelection: false, performSearch: false)
        panel.query.stringValue = "hit"; panel.run(next: true, restart: true)
        checks["countLimitIsHonest"] = panel.status.stringValue.contains("1000+") || panel.status.stringValue.contains("统计受限")
        feed("one token two token\r\n")
        panel.query.stringValue = "token"; panel.run(next: true, restart: true)
        checks["panelCounter"] = panel.status.stringValue == "1 / 2"
        terminal.feed(text: "new token\r\n"); panel.bufferDidChange()
        panel.navigate(next: true)
        checks["panelNavigationAfterOutput"] = panel.status.stringValue == "2 / 3"
        panel.navigate(next: true)
        checks["panelNavigationToNewOutput"] = panel.status.stringValue == "3 / 3"
        panel.query.stringValue = "missing"; panel.run(next: true, restart: true)
        checks["emptyResultsDisableNavigation"] = !panel.next.isEnabled && panel.status.stringValue.contains("没有")
        panel.query.stringValue = ""; panel.run(next: true, restart: true)
        checks["clearQueryClearsSelection"] = !terminal.selection.active && !panel.next.isEnabled
        for width in [220, 760] {
            previewWindow.setContentSize(NSSize(width: width, height: 400)); pane.view.layoutSubtreeIfNeeded(); panel.layoutSubtreeIfNeeded()
            checks["compactSearchFits\(width)"] = [panel.query, panel.previous, panel.next, panel.closeButton, panel.status, panel.optionsButton].allSatisfy { panel.bounds.contains($0.frame) }
        }
        feed("developer@server:~$ journalctl -n 4\r\nINFO  服务启动完成\r\nERROR 连接超时 192.0.2.10\r\nWARN  准备重试\r\nERROR 连接失败 192.0.2.20\r\n")
        // Buffer resets in the fixtures also reset the terminal palette.
        pane.apply(preferences)
        panel.query.stringValue = "ERROR"; panel.run(next: true, restart: true)
        capture(pane.view, name: "search-terminal")
        let marked = NSTextView(); marked.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        checks["IMEEnterNotNavigation"] = !panel.control(panel.query, textView: marked, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        marked.unmarkText()
        checks["escapeConsumed"] = panel.control(panel.query, textView: marked, doCommandBy: #selector(NSResponder.cancelOperation(_:))) && panel.isHidden

        var config = controller.configuration
        var a = SessionProfile(name: "开发 café", group: "生产/华东", host: "192.0.2.10", port: 2222, username: "root")
        a.kind = .ssh
        var b = SessionProfile(name: "文件节点", group: "研发/海外", host: "192.0.2.20", username: "deploy"); b.kind = .sftp
        config.profiles = [a, b, .local]; config.directories = ["生产/华东/空目录", "研发/海外/归档"]
        controller.configuration = config
        let manager = SessionManager(workspace: controller)
        manager.window?.appearance = NSAppearance(named: .aqua)
        let content = manager.window!.contentView!
        let field = descendants(content).compactMap { $0 as? NSSearchField }.first!
        let table = descendants(content).compactMap { $0 as? NSTableView }.first!
        let scope = descendants(content).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("全部目录") }!
        func search(_ text: String) { field.stringValue = text; manager.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field)); content.layoutSubtreeIfNeeded() }
        manager.reveal(a); search("cafe ROOT 2222")
        checks["multiTermPortAndAccentSearch"] = manager.visibleProfiles.map(\.id) == [a.id]
        search("sftp deploy")
        checks["directoryScopeRespected"] = manager.visibleProfiles.isEmpty
        scope.selectItem(at: 1); manager.reload()
        checks["globalScopeFindsOtherDirectory"] = manager.visibleProfiles.map(\.id) == [b.id] && manager.selectedProfile?.id == b.id
        checks["searchContextTargetsActualResult"] = manager.contextMenu(for: table.selectedRow).items.contains { $0.title == "打开 SSH 终端" }
        search("192.0.2.10")
        checks["selectionDoesNotStayAtOldRow"] = manager.selectedProfile?.id == a.id
        search("空目录")
        checks["nestedEmptyDirectoryIsSearchable"] = table.numberOfRows == 2 && manager.visibleProfiles.isEmpty
        let parent = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        checks["parentStaysFirstDuringSearch"] = parent?.textField?.stringValue == "../"
        search("nothing-matches")
        checks["sessionNoResultState"] = manager.selectedProfile == nil && descendants(content).compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue.contains("没有匹配") }
        search("")
        checks["clearRestoresDirectoryListing"] = manager.visibleProfiles.map(\.id) == [a.id]
        manager.showFiles { _ in }; manager.window?.orderOut(nil); search("local")
        checks["filePickerNeverReturnsLocalSession"] = manager.visibleProfiles.isEmpty
        checks["managerIMEEnterNotConnect"] = {
            marked.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
            return !manager.control(field, textView: marked, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }()
        marked.unmarkText()
        for width in [720, 1120] {
            manager.window?.setContentSize(NSSize(width: width, height: 550)); content.layoutSubtreeIfNeeded()
            checks["managerFiltersFit\(width)"] = [field, scope, manager.kindFilter].allSatisfy { content.bounds.contains($0.convert($0.bounds, to: content)) }
        }
        search("192.0.2")
        capture(content, name: "search-sessions")
        checks["allTestsAvoidRealConnections"] = controller.tabs.isEmpty
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        let destination = ProcessInfo.processInfo.environment["OSHELL_SEARCH_OUTPUT"] ?? "/tmp/oshell-search-result.json"
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: destination))
        print(report); pane.shutdown(); previewWindow.close(); manager.close(); controller.shutdown(); NSApp.terminate(nil)
    }
}
