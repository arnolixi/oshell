// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

private final class TabTestBackend: RemoteFileBackend {
    let description: String
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var cancelled = false, uploading = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var uploadStarted: Bool { lock.lock(); defer { lock.unlock() }; return uploading }
    init(_ name: String) { description = name }
    func connect() throws {}
    func canonicalPath(_ path: String) throws -> String { path }
    func list(_ path: String) throws -> [RemoteFileEntry] {
        if isCancelled { throw ModelError.invalid("已取消") }
        return [RemoteFileEntry(name: description + "-" + path.replacingOccurrences(of: "/", with: "") + ".txt", size: 12, modified: nil, directory: false, symbolicLink: false)]
    }
    func upload(_ local: URL, to remote: String, progress: @escaping (UInt64, UInt64) -> Void) throws {
        lock.lock(); uploading = true; lock.unlock(); progress(1, 10)
        _ = gate.wait(timeout: .now() + 8)
        if isCancelled { throw ModelError.invalid("已取消传输") }
        progress(10, 10)
    }
    func download(_ remote: String, to local: URL, progress: @escaping (UInt64, UInt64) -> Void) throws {}
    func mkdir(_ path: String) throws {}
    func rename(_ source: String, to destination: String) throws {}
    func remove(_ path: String, directory: Bool) throws {}
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); gate.signal() }
}

enum FileTabsTest {
    static func run(_ controller: WorkspaceController) {
        var checks = [String: Bool](), finished = false
        func stage(_ value: String) {
            let path = ProcessInfo.processInfo.environment["OSHELL_FILETABS_OUTPUT"] ?? "/tmp/oshell-filetabs.json"
            try? Data(value.utf8).write(to: URL(fileURLWithPath: path + ".stage"))
        }
        stage("init")
        var backends = [TabTestBackend]()
        let manager = RemoteFileWindow(workspace: controller) { profile in
            let backend = TabTestBackend(profile.name); backends.append(backend); return backend
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func accept(_ title: String) {
            let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
                if finished { timer.invalidate(); return }
                if NSApp.modalWindow != nil {
                    stage("accept-" + title); timer.invalidate(); NSApp.stopModal(withCode: .alertFirstButtonReturn)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timer, forMode: .common)
        }
        func finish() {
            guard !finished else { return }; finished = true
            manager.close(); controller.shutdown()
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            let path = ProcessInfo.processInfo.environment["OSHELL_FILETABS_OUTPUT"] ?? "/tmp/oshell-filetabs.json"
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
            print(report); NSApp.terminate(nil)
        }
        func wait(_ label: String, _ condition: @escaping () -> Bool, _ then: @escaping () -> Void) {
            stage(label)
            let deadline = Date().addingTimeInterval(10)
            func poll() {
                guard !finished else { return }
                if condition() { checks[label] = true; then() }
                else if Date() > deadline { checks[label] = false; finish() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() } }
            }
            poll()
        }
        let watchdog = Timer(timeInterval: 35, repeats: false) { _ in
            guard !finished else { return }; checks["watchdogTimeout"] = false
            if NSApp.modalWindow != nil { NSApp.abortModal() }; finish()
        }
        RunLoop.main.add(watchdog, forMode: .modalPanel); RunLoop.main.add(watchdog, forMode: .common)
        let ssh = SessionProfile(name: "SSH", group: "", host: "ssh.test")
        let sftp = SessionProfile(name: "SFTP", group: "", kind: .sftp, host: "sftp.test")
        let ftp = SessionProfile(name: "FTP", group: "", kind: .ftp, host: "ftp.test", port: 21, username: "anonymous")
        checks["catalogSaved"] = controller.saveConfiguration(Configuration(profiles: [ssh, sftp, ftp, .local]))
        stage("catalog")
        let catalog = SessionManager(workspace: controller); catalog.show()
        for (index, kind) in [(1, SessionKind.ssh), (2, .sftp), (3, .ftp)] {
            catalog.kindFilter.selectItem(at: index); catalog.reload()
            checks["filter" + kind.title] = catalog.visibleProfiles.map(\.kind) == [kind]
        }
        catalog.showFiles { _ in }
        checks["filePickerExcludesLocal"] = catalog.visibleProfiles.count == 3 && catalog.visibleProfiles.allSatisfy { $0.kind != .local }
        let root = catalog.window!.contentView!; catalog.window?.setContentSize(NSSize(width: 720, height: 400)); root.layoutSubtreeIfNeeded()
        checks["catalogGeometry"] = descendants(root).filter { $0 is NSButton || $0 is NSSearchField }.allSatisfy { root.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: root)) }
        catalog.close()
        for profile in [sftp, ftp] {
            let editor = SessionEditor(profile, profiles: controller.credentialProfiles, directories: [], initialDirectory: "")
            accept("保存")
            let saved = editor.run()
            checks["editorSaves" + profile.kind.title] = saved?.kind == profile.kind && saved?.host == profile.host && saved?.port == profile.port
        }
        for kind in [SessionKind.sftp, .ftp] {
            stage("editor-" + kind.title)
            let editor = SessionEditor(nil, profiles: controller.credentialProfiles, directories: [], initialDirectory: "", kind: kind)
            checks["editorProtocol" + kind.title] = editor.protocolKind.titleOfSelectedItem == kind.title
            checks["editorPages" + kind.title] = kind == .ftp ? !editor.pageTitles.contains("代理") : editor.pageTitles.contains("代理")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { _ = PopupKeyboard.dismiss(window: editor.dialog.window) }
            checks["editorCancel" + kind.title] = editor.dialog.runModal() == .alertSecondButtonReturn
        }
        stage("open-tabs")
        manager.showWindow(nil); manager.open(sftp, directory: "/one"); let first = manager.selectedSession!
        manager.open(ftp, directory: "/two"); let second = manager.selectedSession!
        wait("bothConnected", { first.connected && second.connected }) {
            first.filterText = "SFTP"; second.filterText = "FTP"
            manager.select(first)
            checks["tabRestoresState"] = first.directory == "/one" && second.directory == "/two" && first.filterText == "SFTP" && second.filterText == "FTP"
            checks["tabDoesNotCancelOtherConnection"] = !backends[0].isCancelled && !backends[1].isCancelled
            checks["onlySelectedViewAttached"] = first.view.window === manager.window && second.view.window == nil
            first.navigate("/changed"); manager.select(second)
            wait("backgroundNavigationFinishes", { first.directory == "/changed" && !first.hasActiveOperation }) {
                checks["backgroundDoesNotReplaceActiveDirectory"] = second.directory == "/two" && manager.selectedSession === second
                manager.select(first)
                accept("上传")
                stage("upload-dialog")
                first.upload([URL(fileURLWithPath: "/tmp/filetabs-test-upload.txt")], to: "/changed")
                wait("backgroundUploadStarted", { backends[0].uploadStarted }) {
                    manager.select(second); second.navigate("/independent")
                    wait("otherTabWorksDuringTransfer", { second.directory == "/independent" }) {
                        checks["transferContinuesWhenHidden"] = first.hasActiveOperation && !backends[0].isCancelled && manager.hasActiveOperation
                        accept("关闭标签")
                        stage("close-busy-tab")
                        manager.closeTab(first.id)
                        checks["closeOnlyCancelsOwnTab"] = backends[0].isCancelled && !backends[1].isCancelled && first.closed && manager.sessions.count == 1 && manager.selectedSession === second
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            checks["lateCallbackCannotRestoreClosedTab"] = manager.sessions.count == 1 && second.directory == "/independent"
                            for size in [NSSize(width: 800, height: 490), NSSize(width: 1180, height: 760)] {
                                manager.window?.setContentSize(size); let content = manager.window!.contentView!; content.layoutSubtreeIfNeeded()
                                checks["fileGeometry\(Int(size.width))"] = descendants(content).filter { $0 is NSButton || $0 is NSSearchField }.allSatisfy { content.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: content)) }
                            }
                            stage("close-window")
                            manager.close()
                            checks["windowCloseReleasesAllTabs"] = second.closed && backends.allSatisfy(\.isCancelled) && manager.sessions.isEmpty
                            finish()
                        }
                    }
                }
            }
        }
    }
}
