// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit

enum PopupKeyboardTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool]()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) } }
        checks["bareEscapeRecognized"] = PopupKeyboard.isEscape(keyCode: 53, modifiers: [])
        checks["capsLockEscapeRecognized"] = PopupKeyboard.isEscape(keyCode: 53, modifiers: [.capsLock])
        checks["modifiedEscapeNotIntercepted"] = [NSEvent.ModifierFlags.command, .option, .control, .shift].allSatisfy { !PopupKeyboard.isEscape(keyCode: 53, modifiers: $0) }
        checks["otherKeysNotIntercepted"] = !PopupKeyboard.isEscape(keyCode: 36, modifiers: [])
        let hotkey = NSApp.mainMenu.flatMap { menuItems($0).first { $0.action == #selector(WorkspaceController.showSessionManager) && $0.keyEquivalent == "o" && $0.keyEquivalentModifierMask == [.command, .shift] } }
        checks["sessionCommandShiftORegistered"] = hotkey != nil
        controller.newLocal(); let tab = controller.selectedTab
        if let hotkey { _ = NSApp.sendAction(hotkey.action!, to: hotkey.target, from: hotkey) }
        let session = NSApp.windows.first { $0.title == "会话管理" && $0.isVisible }
        if let session {
            if let search = descendants(session.contentView!).first(where: { $0 is NSSearchField }) { session.makeFirstResponder(search) }
            checks["sessionClosesWithSearchFocused"] = PopupKeyboard.dismiss(window: session) && !session.isVisible
            controller.showSessionManager()
            checks["sessionCanReopen"] = session.isVisible
            let menu = NSMenu()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            checks["trackingMenuKeepsParentOpen"] = !PopupKeyboard.dismiss(window: session) && session.isVisible
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            checks["dismissAfterMenuEnds"] = PopupKeyboard.dismiss(window: session) && !session.isVisible
        } else { checks["sessionWindowOpened"] = false }
        checks["terminalSessionPreserved"] = controller.selectedTab === tab && tab?.activePane.ended == false
        checks["mainTerminalWindowExcluded"] = !PopupKeyboard.dismiss(window: controller.window!) && controller.window!.isVisible
        controller.showQuickCommands()
        if let window = controller.commandManager?.window { checks["quickCommandManagerCloses"] = PopupKeyboard.dismiss(window: window) && !window.isVisible }
        controller.showHighlights()
        if let window = controller.highlightManager?.window { checks["highlightManagerCloses"] = PopupKeyboard.dismiss(window: window) && !window.isVisible }
        let files = RemoteFileWindow(workspace: controller); var cleanup = false
        files.onClosed = { cleanup = true }; files.showWindow(nil)
        checks["fileManagerCloses"] = PopupKeyboard.dismiss(window: files.window!) && !files.window!.isVisible
        checks["fileManagerRunsCloseCleanup"] = cleanup

        func cancel(_ alert: PopupAlert, beforeDismiss: (() -> Void)? = nil) -> NSApplication.ModalResponse {
            var routed = false
            let deadline = Date().addingTimeInterval(5)
            func dismissWhenModal() {
                if NSApp.modalWindow === alert.window {
                    beforeDismiss?(); routed = PopupKeyboard.dismiss(window: alert.window)
                    if !routed { NSApp.abortModal() }
                }
                else if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: dismissWhenModal) }
                else { NSApp.abortModal() }
            }
            DispatchQueue.main.async(execute: dismissWhenModal)
            let result = alert.runModal()
            checks["modalRouting-\(alert.messageText)"] = routed
            checks["modalHidden-\(alert.messageText)"] = !alert.window.isVisible
            checks["registrationRemoved-\(alert.messageText)"] = !PopupKeyboard.dismiss(window: alert.window)
            return result
        }
        let edit = PopupAlert(); edit.messageText = "编辑取消"; edit.addButton(withTitle: "保存"); edit.addButton(withTitle: "取消")
        let pair = textEditor("未保存的多行草稿\n第二行"); pair.0.frame = NSRect(x: 0, y: 0, width: 450, height: 160); edit.accessoryView = pair.0; edit.window.initialFirstResponder = pair.1
        checks["multilineEditorCancelsWithoutSave"] = cancel(edit) == .alertSecondButtonReturn
        let ftp = PopupAlert(); ftp.messageText = "取消不是最后一个按钮"; ftp.addButton(withTitle: "连接"); ftp.addButton(withTitle: "取消"); ftp.addButton(withTitle: "删除配置")
        checks["escapeDoesNotDeleteFTPConfig"] = cancel(ftp) == .alertSecondButtonReturn
        let choices = PopupAlert(); choices.messageText = "第三个按钮取消"; choices.addButton(withTitle: "上传"); choices.addButton(withTitle: "下载"); choices.addButton(withTitle: "取消")
        checks["escapeDoesNotStartUploadOrDownload"] = cancel(choices) == .alertThirdButtonReturn
        let single = PopupAlert(); single.messageText = "单个肯定按钮"; single.addButton(withTitle: "执行")
        checks["singleAffirmativeButtonNotActivated"] = cancel(single) != .alertFirstButtonReturn
        let message = PopupAlert(); message.messageText = "普通消息"
        checks["plainMessageDismisses"] = cancel(message) != .alertFirstButtonReturn

        let parent = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.makeKeyAndOrderFront(nil)
        let nested = PopupAlert(); nested.messageText = "内层确认"; nested.addButton(withTitle: "删除"); nested.addButton(withTitle: "取消")
        let result = cancel(nested) {
            checks["outerWindowProtectedByModal"] = !PopupKeyboard.dismiss(window: parent) && parent.isVisible
        }
        checks["onlyInnerDialogCancelled"] = result == .alertSecondButtonReturn && parent.isVisible
        parent.close()
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        let path = ProcessInfo.processInfo.environment["OSHELL_POPUP_OUTPUT"] ?? "/tmp/oshell-popup-keyboard-result.json"
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        print(report); controller.shutdown(); NSApp.terminate(nil)
    }
}
