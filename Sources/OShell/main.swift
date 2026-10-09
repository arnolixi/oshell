// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore
import Darwin

// Explicit, isolated transfer harnesses can exercise offscreen AppKit views
// without taking keyboard focus from the user's foreground application.
private let backgroundTransferTest = ProcessInfo.processInfo.environment["OSHELL_BACKGROUND_TEST"] == "1"
    && ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] != nil
    && CommandLine.arguments.contains(where: { ["--login-password-save-test", "--third-party-import-test", "--keyboard-shortcuts-test", "--toolbar-actions-test", "--quicksend-groups-test", "--tab-behavior-test", "--layout-test", "--zmodem-progress-test", "--zmodem-regression-test", "--file-feature-test", "--search-test", "--host-identity-test", "--session-links-test", "--session-defaults-test", "--shell-integration-test", "--live-keepalive-test", "--appearance-test", "--quicksend-persistence-test", "--local-password-test", "--management-test", "--startup-protection-test", "--tab-drag-test", "--tab-actions-test", "--master-removal-test", "--update-feature-test", "--update-integration-test", "--terminal-focus-test", "--terminal-symbols-test", "--session-directory-test", "--quicksend-focus-test", "--arrangement-scroll-test", "--tab-number-test", "--links-catalog-test", "--named-tab-groups-test"].contains($0) })

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: WorkspaceController!
    var windows: WorkspaceWindows!
    private var launchServer: ExternalLaunchServer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bundled brand explicitly instead of a stale LaunchServices icon.
        if let url = Bundle.main.url(forResource: "OShell", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        PopupKeyboard.install()
        if CommandLine.arguments.contains("--encrypted-startup-test") { EncryptedStartupTest.install() }
        let directory: URL
        var openingMaster: String?
        if let override = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] { directory = URL(fileURLWithPath: override) }
        else {
            let location = StorageLocation()
            do {
                if try location.needsActivation() {
                    NSApp.activate(ignoringOtherApps: true)
                    guard let password = PasswordVault.promptMaster(title: "输入主密码以启用本地加密副本", creating: false) else { NSApp.terminate(nil); return }
                    openingMaster = password
                }
                directory = try location.activatePending(master: openingMaster)
            }
            catch {
                let alert = PopupAlert(); alert.messageText = "无法打开数据目录"; alert.informativeText = error.localizedDescription
                if (try? location.pending()) != nil {
                    alert.addButton(withTitle: "取消切换，使用原目录"); alert.addButton(withTitle: "退出")
                    guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
                    do { try location.schedule(nil); directory = try location.activeDirectory() }
                    catch { Dialogs.message(error.localizedDescription); NSApp.terminate(nil); return }
                } else {
                    alert.informativeText += "\n\n可返回迁移时保留的默认本地副本；共享目录中的文件不会删除。"
                    alert.addButton(withTitle: "退出"); alert.addButton(withTitle: "返回默认本地目录")
                    guard alert.runModal() == .alertSecondButtonReturn else { NSApp.terminate(nil); return }
                    do { directory = try location.restoreDefaultDirectory(); openingMaster = nil }
                    catch { Dialogs.message(error.localizedDescription); NSApp.terminate(nil); return }
                }
            }
        }
        let harness = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] != nil && (CommandLine.arguments.contains(where: { $0.hasSuffix("-test") || $0.hasPrefix("--memory-") }) || ProcessInfo.processInfo.environment.keys.contains { $0.hasSuffix("_TEST_ROOT") })
        let shared = !harness && ((try? StorageLocation().syncDirectory()) != nil || FileManager.default.fileExists(atPath: WebDAVSync.settingsURL.path))
        let store = ConfigurationStore(directory: directory, masterPassword: openingMaster, requiresMasterProtection: shared)
        if let data = try? SharedDataFile.readIfPresent(store.url), SharedVault.isEncrypted(data) {
            while true {
                if let password = store.masterPassword, (try? store.load()).flatMap({ try? MasterPasswordProtection.verifyStartup($0, password: password) }) != nil { break }
                NSApp.activate(ignoringOtherApps: true)
                guard let password = PasswordVault.promptMaster(title: "解锁 OShell 加密数据", creating: false) else { NSApp.terminate(nil); return }
                store.masterPassword = password
                do { let config = try store.load(); try MasterPasswordProtection.verifyStartup(config, password: password); break }
                catch { store.masterPassword = nil; Dialogs.message(error.localizedDescription) }
            }
        }
        controller = WorkspaceController(store: store)
        do { launchServer = try ExternalLaunchServer(workspace: controller) }
        catch {
            if CommandLine.arguments.contains("--external-launch-service") { NSApp.terminate(nil); return }
            // Terminal use remains available if a duplicate instance owns the endpoint.
        }
        guard controller.unlockAtStartup() else { NSApp.terminate(nil); return }
        windows = WorkspaceWindows(initial: controller)
        windows.onActiveChanged = { [weak self] in self?.controller = $0 }
        launchServer?.workspaceProvider = { [weak self] in self?.windows?.externalWorkspace() }
        buildMenu()
        windows.activate(controller)
        if !CommandLine.arguments.contains(where: { $0.hasSuffix("-test") }) { windows.webDAV.schedule() }
        if !CommandLine.arguments.contains(where: { $0.hasSuffix("-test") }) { do { try controller.appUpdater.configure() } catch { Dialogs.message(error.localizedDescription) } }
        if !backgroundTransferTest { controller.show(); NSApp.activate(ignoringOtherApps: true) }
        if !CommandLine.arguments.contains(where: { $0.hasSuffix("-test") }), SharedConflictDrafts.exists(for: controller.store) {
            DispatchQueue.main.async {
                if NSApp.modalWindow == nil { Dialogs.message("本机有尚未处理的同步草稿，请通过“会话 → 处理同步冲突…”选择保留的版本。草稿处理前不会自动载入或覆盖共享数据。") }
            }
        }
        if CommandLine.arguments.contains("--external-launch-service"), ProcessInfo.processInfo.environment["OSHELL_SFTP_REUSE_TEST_ROOT"] != nil { SFTPReuseTest.run(controller) }
        if CommandLine.arguments.contains("--external-launch-service"), ProcessInfo.processInfo.environment["OSHELL_ZOC_CLONE_TEST_ROOT"] != nil { SSHCloneTest.run(controller) }
        if CommandLine.arguments.contains("--external-launch-service"), ProcessInfo.processInfo.environment["OSHELL_ZOC_TEST_ROOT"] != nil { ZOCLaunchTest.run(controller) }
        if CommandLine.arguments.contains("--external-launch-service"), ProcessInfo.processInfo.environment["OSHELL_FILE_LAUNCH_TEST_ROOT"] != nil { FileLaunchTest.run(controller) }
        if CommandLine.arguments.contains("--encrypted-startup-test") { EncryptedStartupTest.complete(controller) }
        if CommandLine.arguments.contains("--command-input-test") { CommandInputTest.run(controller) }
        if CommandLine.arguments.contains("--directory-sync-test") { DirectorySyncTest.run(controller) }
        if CommandLine.arguments.contains("--webdav-test") { WebDAVFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--shared-conflict-test") { SharedConflictTest.run(controller) }
        if CommandLine.arguments.contains("--storage-sync-test") { StorageSyncTest.run(controller) }
        if CommandLine.arguments.contains("--multi-window-test") { MultiWindowTest.run(controller) }
        if CommandLine.arguments.contains("--named-tab-groups-test") { NamedTabGroupsTest.run(controller) }
        if CommandLine.arguments.contains("--links-catalog-test") { LinksCatalogTest.run(controller) }
        if CommandLine.arguments.contains("--tab-number-test") { TabNumberTest.run(controller) }
        if CommandLine.arguments.contains("--arrangement-scroll-test") { ArrangementScrollTest.run(controller) }
        if CommandLine.arguments.contains("--login-password-save-test") { LoginPasswordSavingTest.run(controller) }
        if CommandLine.arguments.contains("--third-party-import-test") { ThirdPartyImportTest.run(controller) }
        if CommandLine.arguments.contains("--keyboard-shortcuts-test") { KeyboardShortcutsTest.run(controller) }
        if CommandLine.arguments.contains("--toolbar-actions-test") { ToolbarActionsTest.run(controller) }
        if CommandLine.arguments.contains("--quicksend-groups-test") { QuickSendGroupsTest.run(controller) }
        if CommandLine.arguments.contains("--quicksend-focus-test") { QuickSendFocusTest.run(controller) }
        if CommandLine.arguments.contains("--session-directory-test") { SessionDirectoryTest.run(controller) }
        if CommandLine.arguments.contains("--terminal-symbols-test") { TerminalSymbolsTest.run(controller) }
        if CommandLine.arguments.contains("--terminal-focus-test") { TerminalFocusTest.run(controller) }
        if CommandLine.arguments.contains("--update-feature-test") { UpdateFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--update-integration-test") { UpdateIntegrationTest.run(controller) }
        if CommandLine.arguments.contains("--master-removal-test") { MasterRemovalTest.run(controller) }
        if CommandLine.arguments.contains("--tab-actions-test") { TabActionsTest.run(controller) }
        if CommandLine.arguments.contains("--tab-drag-test") { TabDragTest.run(controller) }
        if CommandLine.arguments.contains("--startup-protection-test") { StartupProtectionTest.run(controller) }
        if CommandLine.arguments.contains("--local-password-test") { LocalPasswordFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--quicksend-persistence-test") { QuickSendPersistenceTest.run(controller) }
        if CommandLine.arguments.contains("--appearance-test") { AppearanceFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--live-keepalive-test") { LiveKeepAliveTest.run(controller) }
        if CommandLine.arguments.contains("--shell-integration-test") { ShellIntegrationTest.run(controller) }
        if CommandLine.arguments.contains("--session-defaults-test") { SessionDefaultsTest.run(controller) }
        if CommandLine.arguments.contains("--session-links-test") { SessionLinksTest.run(controller) }
        if CommandLine.arguments.contains("--search-test") { SearchFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--smoke-test") { SmokeTest.run(controller) }
        if CommandLine.arguments.contains("--integration-test") { IntegrationTest.run(controller) }
        if CommandLine.arguments.contains("--stress-test") { StressTest.run(controller) }
        if CommandLine.arguments.contains("--password-test") { PasswordTest.run(controller) }
        if CommandLine.arguments.contains("--session-test") { SessionFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--zmodem-progress-test") { ZmodemProgressUITest.run(controller) }
        if CommandLine.arguments.contains("--zmodem-regression-test") { ZmodemRegressionTest.run(controller) }
        if CommandLine.arguments.contains("--ended-session-test") { EndedSessionTest.run(controller) }
        if CommandLine.arguments.contains("--file-feature-test") { FileFeatureTest.run(controller) }
        if CommandLine.arguments.contains("--operator-input-test") { OperatorInputTest.run(controller) }
        if CommandLine.arguments.contains("--operator-ui-test") { OperatorUITest.run(controller) }
        if CommandLine.arguments.contains("--session-fullscreen-test") { SessionFullscreenTest.run(controller) }
        if CommandLine.arguments.contains("--popup-keyboard-test") { PopupKeyboardTest.run(controller) }
        if CommandLine.arguments.contains("--memory-profile") { MemoryProfile.run(controller) }
        if CommandLine.arguments.contains("--memory-cycles") { MemoryCycleProfile.run(controller) }
        if CommandLine.arguments.contains("--idle-memory-test") { IdleMemoryTest.run(controller) }
        if CommandLine.arguments.contains("--tab-behavior-test") { TabBehaviorTest.run(controller) }
        if CommandLine.arguments.contains("--compact-layout-preview") { CompactLayoutPreview.run(controller) }
        if CommandLine.arguments.contains("--host-identity-test") { HostIdentityTest.run(controller) }
        if CommandLine.arguments.contains("--session-list-test") { SessionListUITest.run(controller) }
        if CommandLine.arguments.contains("--management-test") { ManagementUITest.run(controller) }
        if CommandLine.arguments.contains("--quicksend-test") { QuickSendTest.run(controller) }
        if CommandLine.arguments.contains("--filetabs-test") { FileTabsTest.run(controller) }
        if CommandLine.arguments.contains("--unread-output-test") { UnreadOutputTest.run(controller) }
        if CommandLine.arguments.contains("--ended-broadcast-test") { EndedBroadcastTest.run(controller) }
        if CommandLine.arguments.contains("--local-tool-test") { LocalToolTest.run(controller) }
        if CommandLine.arguments.contains("--filetabs-integration-test") { FileTabsIntegrationTest.run(controller) }
        if CommandLine.arguments.contains("--layout-test") { LayoutTest.run(controller) }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !CommandLine.arguments.contains(where: { $0.hasSuffix("-test") }) else { return }
        windows?.reloadSharedConfiguration(interactive: false)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard windows?.canQuit() ?? true else { return .terminateCancel }
        controller?.completeStartupUnlock(false); launchServer?.stop(); return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { windows?.webDAV.diagnostics.flush(); launchServer?.stop(); SSHConnectionGroup.finishCleanup() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { windows?.externalWorkspace()?.show(); return true }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(); menu.autoenablesItems = false
        let item = menu.addItem(withTitle: "新建窗口", action: #selector(newWindow), keyEquivalent: "")
        // Target the app, so this remains usable after the last workspace closes.
        item.target = self; item.isEnabled = windows != nil && NSApp.modalWindow == nil
        return menu
    }
    @objc func newWindow() {
        guard let windows, NSApp.modalWindow == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        windows.newWindow()
    }
    private func buildMenu() {
        let root = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let submenu = NSMenu(title: title)
            item.submenu = submenu; root.addItem(item); return submenu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = target ?? controller
        }
        let app = menu("OShell")
        add(app, "关于 OShell", #selector(WorkspaceController.showAbout))
        add(app, "开源许可…", #selector(WorkspaceController.showOpenSourceLicenses))
        add(app, "检查更新…", #selector(WorkspaceController.checkForUpdates))
        add(app, "更新设置…", #selector(WorkspaceController.showUpdatePreferences))
        add(app, "设置…", #selector(WorkspaceController.showPreferences), ",")
        add(app, "主题与配色…", #selector(WorkspaceController.showAppearancePreferences))
        add(app, "锁定主密码", #selector(WorkspaceController.lockPasswords))
        add(app, "修改主密码…", #selector(WorkspaceController.changeMasterPassword))
        add(app, "清除主密码…", #selector(WorkspaceController.clearMasterPassword))
        app.addItem(.separator()); add(app, "隐藏 OShell", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "退出 OShell", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("会话")
        add(file, "新建窗口", #selector(WorkspaceController.newWindow), "n", [.command, .shift], target: self)
        add(file, "会话管理…", #selector(WorkspaceController.showSessionManager), "o", [.command, .shift])
        add(file, "立即同步共享数据", #selector(WorkspaceController.syncWebDAVNow))
        add(file, "处理同步冲突…", #selector(WorkspaceController.resolvePendingSharedConflicts))
        add(file, "放弃本机同步草稿…", #selector(WorkspaceController.discardPendingSharedConflicts))
        add(file, "刷新本地 / 共享数据", #selector(WorkspaceController.reloadSharedConfiguration))
        add(file, "导入会话…", #selector(WorkspaceController.importSessions))
        add(file, "导出全部会话…", #selector(WorkspaceController.exportSessions))
        add(file, "会话默认属性…", #selector(WorkspaceController.showSessionDefaults))
        add(file, "当前会话完整属性…", #selector(WorkspaceController.editCurrentSessionProfile))
        add(file, "当前会话属性…", #selector(WorkspaceController.showCurrentSessionProperties))
        add(file, "新建会话…", #selector(WorkspaceController.newSession), "n")
        add(file, "连接所选会话", #selector(WorkspaceController.connectSelected), "\r")
        add(file, "新建空白标签页", #selector(WorkspaceController.newBlankTab))
        add(file, "本地终端", #selector(WorkspaceController.newLocal), "t")
        add(file, "编辑会话…", #selector(WorkspaceController.editSession)); add(file, "删除会话…", #selector(WorkspaceController.deleteSession))
        file.addItem(.separator()); add(file, "重新连接", #selector(WorkspaceController.reconnect), "r", [.command, .shift])
        add(file, "关闭当前分屏", #selector(WorkspaceController.closePane), "w")
        add(file, "关闭当前标签", #selector(WorkspaceController.closeTab), "w", [.command, .shift])
        windows.quickMenu = menu("快捷连接")
        let edit = menu("编辑")
        add(edit, "复制", #selector(NSText.copy(_:)), "c", target: nil)
        edit.items.last?.target = nil
        add(edit, "粘贴", #selector(NSText.paste(_:)), "v", target: nil); edit.items.last?.target = nil
        add(edit, "全选", #selector(NSText.selectAll(_:)), "a", target: nil); edit.items.last?.target = nil
        add(edit, "搜索…", #selector(WorkspaceController.findInTerminal), "f")
        add(edit, "下一个匹配", #selector(WorkspaceController.findNextInTerminal), "g")
        add(edit, "上一个匹配", #selector(WorkspaceController.findPreviousInTerminal), "g", [.command, .shift])
        let view = menu("视图")
        add(view, "新建标签组…", #selector(WorkspaceController.newNamedTabGroup))
        add(view, "显示全部标签组", #selector(WorkspaceController.showAllTabGroups))
        view.addItem(.separator())
        for mode in TabArrangement.allCases {
            add(view, mode.title, #selector(WorkspaceController.changeArrangement(_:)))
            view.items.last?.tag = mode.rawValue; view.items.last?.toolTip = mode.hint
        }
        view.addItem(.separator())
        add(view, "新建左右分屏", #selector(WorkspaceController.splitVertical), "d")
        add(view, "新建上下分屏", #selector(WorkspaceController.splitHorizontal), "d", [.command, .shift])
        add(view, "开始 / 停止日志记录…", #selector(WorkspaceController.toggleLogging), "l", [.command, .shift])
        add(view, "下一个标签", #selector(WorkspaceController.nextTab), "\t", .control)
        add(view, "上一个标签", #selector(WorkspaceController.previousTab), "\t", [.control, .shift])
        add(view, "切回最近使用的标签", #selector(WorkspaceController.lastUsedTab), "`", .control)
        let numberedItem = NSMenuItem(title: "按编号跳转", action: nil, keyEquivalent: "")
        let numberedMenu = NSMenu(title: "按编号跳转"); numberedItem.submenu = numberedMenu; view.addItem(numberedItem)
        for number in 1...9 {
            add(numberedMenu, "跳到标签 \(number)", #selector(WorkspaceController.selectNumberedTab(_:)), String(number))
            numberedMenu.items.last?.tag = number
        }
        add(numberedMenu, "输入标签编号…", #selector(WorkspaceController.chooseTabNumber), "0")
        add(view, "刷新标题识别", #selector(WorkspaceController.refreshCurrentHostIdentity))
        view.items.last?.toolTip = "在目标主机的 shell 命令提示符下使用，只读获取当前主机名和 IP。"
        let tools = menu("工具")
        add(tools, "链接栏", #selector(WorkspaceController.toggleSessionLinkBar))
        add(tools, "快速命令管理器…", #selector(WorkspaceController.showQuickCommands))
        add(tools, "快速发送栏", #selector(WorkspaceController.toggleQuickSendBar))
        add(tools, "定位快速发送栏", #selector(WorkspaceController.focusQuickSendBar), "k", [.command, .shift])
        add(tools, "撰写窗", #selector(WorkspaceController.toggleComposer), "i", [.command, .shift])
        add(tools, "同步输入…", #selector(WorkspaceController.configureSyncInput))
        add(tools, "停止同步输入", #selector(WorkspaceController.stopSyncInput))
        add(tools, "文件管理（SFTP / FTP）…", #selector(WorkspaceController.showFiles))
        add(tools, "突出显示集…", #selector(WorkspaceController.showHighlights))
        windows.commandMenu = menu("快速命令")
        let window = menu("窗口"); NSApp.windowsMenu = window
        add(window, "新建窗口", #selector(WorkspaceController.newWindow), target: self)
        add(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil); window.items.last?.target = nil
        NSApp.mainMenu = root
        ShortcutRuntime.install(controller.configuration.preferences.keyboardShortcuts, menu: root)
    }
}

if UpdateIntegrationTest.finishRelaunchFixtureIfNeeded() { exit(0) }

// FileZilla-compatible direct URLs/site references use the file launcher.
if let first = CommandLine.arguments.dropFirst().first,
   first.hasPrefix("--site") || first == "-c" || first.lowercased().hasPrefix("ftp://") || first.lowercased().hasPrefix("sftp://") {
    let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OShell-FileZilla.app/Contents/MacOS/OShell-FileZilla").path
    let values = ([bridge] + Array(CommandLine.arguments.dropFirst())).map { strdup($0) } + [nil]
    values.withUnsafeBufferPointer { _ = execv(bridge, UnsafeMutablePointer(mutating: $0.baseAddress!)) }
    FileHandle.standardError.write(Data("文件启动入口缺失，请使用完整 OShell 应用包。\n".utf8)); exit(1)
}

// Also support the path users previously pointed at the main OShell executable.
if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("/") || $0.lowercased().hasPrefix("-ssh") || $0.lowercased().hasPrefix("-connect") || $0.lowercased().hasPrefix("-dev") }) {
    let bridge = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("OShell-ZOC").path
    let values = ([bridge] + Array(CommandLine.arguments.dropFirst())).map { strdup($0) } + [nil]
    values.withUnsafeBufferPointer { buffer in _ = execv(bridge, UnsafeMutablePointer(mutating: buffer.baseAddress!)) }
    FileHandle.standardError.write(Data("OShell-ZOC 启动文件缺失，请使用完整应用包。\n".utf8)); exit(1)
}
let app = NSApplication.shared
signal(SIGPIPE, SIG_IGN)
app.setActivationPolicy(backgroundTransferTest ? .accessory : .regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
