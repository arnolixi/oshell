// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

/// App-owned lifetime; terminals and input targets remain owned by one workspace.
final class WorkspaceWindows {
    private(set) var workspaces: [WorkspaceController]
    private(set) weak var active: WorkspaceController?
    let store: ConfigurationStore
    let updater: AppUpdater
    var quickMenu: NSMenu?
    var commandMenu: NSMenu?
    var onActiveChanged: ((WorkspaceController?) -> Void)?
    private var quitting = false

    init(initial: WorkspaceController) {
        store = initial.store; updater = initial.appUpdater
        workspaces = [initial]; active = initial; initial.windowCoordinator = self
    }
    @discardableResult func newWindow() -> WorkspaceController {
        let workspace = WorkspaceController(store: store)
        workspace.windowCoordinator = self
        // Startup protection is app-wide; opening another window does not unlock
        // the password cache or bypass an explicitly locked credential vault.
        workspace.completeStartupUnlock(!workspace.loadFailed)
        workspaces.append(workspace)
        workspace.window?.setFrameAutosaveName("")
        if let previous = active?.window, let window = workspace.window {
            let screen = previous.screen?.visibleFrame ?? previous.frame
            let origin = NSPoint(x: min(previous.frame.minX + 28, screen.maxX - window.frame.width),
                                 y: max(screen.minY, previous.frame.minY - 28))
            window.setFrameOrigin(origin)
        }
        activate(workspace); workspace.show()
        return workspace
    }
    func activate(_ workspace: WorkspaceController) {
        guard workspaces.contains(where: { $0 === workspace }) else { return }
        active = workspace; updater.useWorkspace(workspace); onActiveChanged?(workspace)
        // Menu-bar actions must never retain or target the first/closed window.
        func retarget(_ menu: NSMenu) {
            for item in menu.items {
                if item.target is WorkspaceController || (item.target == nil && item.action.map { workspace.responds(to: $0) } == true) { item.target = workspace }
                if let submenu = item.submenu { retarget(submenu) }
            }
        }
        if let menu = NSApp.mainMenu { retarget(menu) }
        for other in workspaces where other !== workspace { other.quickMenu = nil; other.commandMenu = nil }
        workspace.quickMenu = quickMenu; workspace.commandMenu = commandMenu
    }
    func remove(_ workspace: WorkspaceController) {
        workspace.quickMenu = nil; workspace.commandMenu = nil
        workspaces.removeAll { $0 === workspace }
        if active === workspace {
            active = nil
            if let next = workspaces.last { activate(next); next.show() }
            else {
                updater.useWorkspace(nil); onActiveChanged?(nil)
                func clear(_ menu: NSMenu) {
                    for item in menu.items {
                        if item.target is WorkspaceController { item.target = nil }
                        if let submenu = item.submenu { clear(submenu) }
                    }
                }
                if let menu = NSApp.mainMenu { clear(menu) }
                quickMenu?.removeAllItems(); commandMenu?.removeAllItems()
            }
        }
        workspace.windowCoordinator = nil
    }
    func publish(_ configuration: Configuration, from source: WorkspaceController) {
        for workspace in workspaces where workspace !== source { workspace.receiveConfiguration(configuration) }
    }
    func externalWorkspace() -> WorkspaceController? {
        guard !quitting else { return nil }
        return active ?? workspaces.last ?? newWindow()
    }
    func canQuit(forUpdate: Bool = false) -> Bool {
        let running = workspaces.reduce(0) { $0 + $1.activeProcessCount }
        let files = workspaces.reduce(0) { $0 + $1.activeFileOperationCount }
        if running > 0 || files > 0 {
            guard Dialogs.confirm(forUpdate ? "安装更新并重新启动？" : "退出 OShell？",
                                  text: "全部 \(workspaces.count) 个窗口中的 \(running) 个终端连接和 \(files) 个文件操作会结束。",
                                  action: forUpdate ? "关闭会话并更新" : "退出") else { return false }
        }
        quitting = true
        workspaces.forEach { $0.shutdown() }
        return true
    }
}
