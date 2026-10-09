// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class WebDAVSync {
    private weak var windows: WorkspaceWindows?
    private let store: ConfigurationStore
    private var task: DispatchWorkItem?, client: WebDAVClient?
    var makeClient: (WebDAVSettings) throws -> WebDAVClient = { try WebDAVClient($0) }
    private(set) var busy = false
    private var token = UUID(), applying = false
    private(set) var status = "尚未同步"
    private var lastError: String?
    static var root: URL { StorageLocation.localStateDirectory }
    static var settingsURL: URL { root.appendingPathComponent("webdav-settings.json") }
    private var baselineURL: URL { Self.root.appendingPathComponent("webdav-baseline.json") }
    var enabled: Bool { FileManager.default.fileExists(atPath: Self.settingsURL.path) }
    init(windows: WorkspaceWindows) { self.windows = windows; store = windows.store }
    func settings(master: String) throws -> WebDAVSettings? {
        guard let data = try SharedDataFile.readIfPresent(Self.settingsURL) else { return nil }
        return try JSONDecoder().decode(WebDAVSettings.self, from: SharedVault.open(data, password: master))
    }
    func configure(_ settings: WebDAVSettings?, master: String) throws {
        guard !busy else { throw ModelError.invalid("WebDAV 正在同步，请完成或取消后再修改连接。") }
        cancel()
        if let settings {
            _ = try settings.directory()
            if let existing = try self.settings(master: master), existing.address == settings.address, existing.username == settings.username {
                try PrivateFile.write(SharedVault.seal(JSONEncoder().encode(settings), password: master), to: Self.settingsURL)
            } else {
                try? FileManager.default.removeItem(at: baselineURL)
                try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
                try PrivateFile.write(SharedVault.seal(JSONEncoder().encode(settings), password: master), to: Self.settingsURL)
            }
            store.requiresMasterProtection = true; store.masterPassword = master
            schedule()
        } else {
            if enabled { try FileManager.default.removeItem(at: Self.settingsURL) }
            try? FileManager.default.removeItem(at: baselineURL)
            if store.url.deletingLastPathComponent().standardizedFileURL == Self.root.standardizedFileURL { store.requiresMasterProtection = false }
            status = "WebDAV 已停用，远端数据保留"
        }
    }
    func cancel() { token = UUID(); task?.cancel(); task = nil; client?.cancel(); client = nil; busy = false }
    func schedule() {
        guard enabled, !applying else { return }
        task?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sync(interactive: false) }; task = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    private static func same(_ a: Configuration, _ b: Configuration) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }
    func sync(interactive: Bool) {
        guard enabled, !busy, NSApp.modalWindow == nil, let workspace = windows?.active else { return }
        guard !SharedConflictDrafts.exists(for: store) else { if interactive { Dialogs.message("请先处理本机同步冲突草稿。"); }; return }
        guard let master = PasswordVault.shared.cachedMaster else { if interactive { Dialogs.message("请先解锁主密码，再同步 WebDAV。"); }; return }
        do {
            try SharingProtection.require(workspace.configuration)
            guard let settings = try settings(master: master) else { return }
            let client = try makeClient(settings), local = workspace.configuration, revision = workspace.configurationRevision, current = UUID()
            token = current; self.client = client; busy = true; status = "正在读取 WebDAV…"
            let baseData = try SharedDataFile.readIfPresent(baselineURL)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { () -> (WebDAVObject?, Configuration?, Configuration?) in
                    let remote = try client.fetch()
                    let decoded = try remote.map { try SharedVault.decode($0.data, password: master) }
                    let base = try baseData.map { try SharedVault.decode($0, password: master) }
                    return (remote, decoded, base)
                }
                DispatchQueue.main.async { [weak self, weak workspace] in
                    guard let self, self.token == current, let workspace else { return }
                    do {
                        let (object, remote, baseline) = try result.get()
                        guard PasswordVault.shared.cachedMaster == master, workspace.configurationRevision == revision else { self.finish(); self.schedule(); return }
                        var resolved = local
                        if var remote {
                            // Same master, different randomized verifier ciphertext on different Macs.
                            // Both envelopes were authenticated before aligning the verifier for comparison.
                            remote.masterPasswordVerifier = local.masterPasswordVerifier
                            if var baseline {
                                baseline.masterPasswordVerifier = local.masterPasswordVerifier
                                let plan = try ConfigurationMerge(base: baseline, local: local, remote: remote)
                                guard let choices = self.choose(plan) else { self.status = "有待确认的会话冲突，稍后重新同步"; self.finish(); return }
                                resolved = try plan.resolve(choices)
                            } else {
                                let alert = PopupAlert(); alert.messageText = "WebDAV 已有共享数据"
                                alert.informativeText = "首次同步：共享端有 \(remote.profiles.count) 个会话，本机有 \(local.profiles.count) 个。请选择加载共享版本，或合并本机会话；不会按时间直接覆盖。"
                                alert.addButton(withTitle: "使用共享版本"); alert.addButton(withTitle: "合并本机会话"); alert.addButton(withTitle: "取消")
                                let response = alert.runModal()
                                if response == .alertFirstButtonReturn { resolved = remote }
                                else if response == .alertSecondButtonReturn {
                                    var base = remote; base.profiles = []
                                    var own = remote; own.profiles = local.profiles
                                    let plan = try ConfigurationMerge(base: base, local: own, remote: remote)
                                    guard let choices = self.choose(plan) else { self.finish(); return }; resolved = try plan.resolve(choices)
                                } else { self.finish(); return }
                            }
                            guard workspace.configurationRevision == revision, PasswordVault.shared.cachedMaster == master else { throw ModelError.invalid("选择期间本机配置发生变化，请重新同步。本机修改已保留。") }
                            let needsUpload = !Self.same(resolved, remote)
                            self.commit(resolved, remote: object, upload: needsUpload, client: client, master: master, revision: revision, workspace: workspace, token: current, interactive: interactive)
                        } else {
                            guard baseline == nil else { throw ModelError.invalid("远端同步文件被删除，未自动重建或覆盖。请确认远端目录后重新配置。") }
                            self.commit(resolved, remote: nil, upload: true, client: client, master: master, revision: revision, workspace: workspace, token: current, interactive: interactive)
                        }
                    } catch { self.fail(error, interactive: interactive) }
                }
            }
        } catch { fail(error, interactive: interactive) }
    }
    private func choose(_ plan: ConfigurationMerge) -> [String: ConfigurationMerge.Choice]? {
        if plan.conflicts.isEmpty { return [:] }
        let alert = PopupAlert(); alert.messageText = "WebDAV 会话冲突"; alert.informativeText = "请逐项选择保留的版本。稍后处理会保留本机离线数据，下次同步继续比较。"
        alert.addButton(withTitle: "确认同步"); alert.addButton(withTitle: "稍后处理")
        let view = SharedConflictView(plan.conflicts); alert.accessoryView = view; let save = alert.buttons[0]; save.isEnabled = false
        view.onReady = { [weak save] in save?.isEnabled = $0 }
        return alert.runModal() == .alertFirstButtonReturn ? view.choices : nil
    }
    private func commit(_ value: Configuration, remote: WebDAVObject?, upload: Bool, client: WebDAVClient, master: String, revision: Int, workspace: WorkspaceController, token: UUID, interactive: Bool) {
        status = upload ? "正在加密并上传…" : "正在载入共享数据…"
        DispatchQueue.global(qos: .utility).async { [weak self, weak workspace] in
            let result = Result { () -> Data in
                let encrypted = try SharedVault.encode(value, password: master)
                if upload { try client.put(encrypted, matching: remote?.etag) }
                return encrypted
            }
            DispatchQueue.main.async { [weak self, weak workspace] in
                guard let self, self.token == token, let workspace else { return }
                do {
                    let encrypted = try result.get()
                    guard PasswordVault.shared.cachedMaster == master else { self.finish(); return }
                    // Baseline records what was actually acknowledged by the server, not newer local edits.
                    let editedWhileSyncing = workspace.configurationRevision != revision
                    if !editedWhileSyncing {
                        self.applying = true; defer { self.applying = false }
                        try self.store.save(value)
                        PasswordVault.shared.acceptSharedConfiguration(value)
                        workspace.acceptSavedConfiguration(value, applyPreferences: true)
                        try PrivateFile.write(encrypted, to: self.baselineURL)
                    }
                    self.status = "同步完成"; self.lastError = nil; self.finish()
                    if editedWhileSyncing { self.schedule() }
                    if interactive { Dialogs.message("WebDAV 同步完成。现有终端连接保持运行。") }
                } catch { self.fail(error, interactive: interactive) }
            }
        }
    }
    private func finish() { busy = false; client = nil }
    private func fail(_ error: Error, interactive: Bool) {
        status = error.localizedDescription; finish()
        if interactive || lastError != status { lastError = status; Dialogs.message(status) }
    }
}
