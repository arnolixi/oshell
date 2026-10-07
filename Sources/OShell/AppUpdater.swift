// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Sparkle
import OShellCore

/// Sparkle owns verification/download/replacement. OShell owns source selection and session shutdown.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private weak var workspace: WorkspaceController?
    private var standard: SPUStandardUpdaterController?
    private var source: UpdateSource?
    private var pendingInstall: (() -> Void)?
    private(set) var started = false
    var hasPendingInstallation: Bool { pendingInstall != nil }
    var canCheck: Bool { pendingInstall != nil || standard?.updater.sessionInProgress != true }
    var isBusy: Bool { standard?.updater.sessionInProgress == true || pendingInstall != nil }
    init(workspace: WorkspaceController) { self.workspace = workspace; super.init() }
    private var configuredRepository: String {
        let value = workspace?.configuration.preferences.updateRepository ?? ""
        return value.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "OShellUpdateRepository") as? String ?? "") : value
    }
    func configure() throws {
        guard let workspace, workspace.isSecurityUnlocked else { return }
        let raw = configuredRepository
        let next = raw.isEmpty ? nil : try UpdateSource(raw)
        guard !isBusy || next == source else { throw ModelError.invalid("更新正在进行，请完成或取消后再修改更新仓库。") }
        source = next
        guard source != nil else { standard?.updater.automaticallyChecksForUpdates = false; return }
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, Data(base64Encoded: publicKey)?.count == 32 else { throw ModelError.invalid("应用缺少更新校验公钥，请使用完整的 OShell 发布版本。") }
        if standard == nil { standard = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil) }
        guard let updater = standard?.updater else { return }
        if !started { try updater.start(); started = true }
        if updater.automaticallyChecksForUpdates != workspace.configuration.preferences.automaticUpdateChecks { updater.automaticallyChecksForUpdates = workspace.configuration.preferences.automaticUpdateChecks }
        if updater.automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = false }
        updater.resetUpdateCycleAfterShortDelay()
    }
    func check() {
        guard let workspace, workspace.isSecurityUnlocked else { return }
        if pendingInstall != nil { resumeInstallation(); return }
        if configuredRepository.isEmpty { workspace.showUpdatePreferences() }
        guard !configuredRepository.isEmpty else { return }
        do {
            try configure()
            guard let standard, standard.updater.canCheckForUpdates else { return }
            standard.checkForUpdates(nil)
        } catch { Dialogs.message("无法检查更新：\(error.localizedDescription)") }
    }
    func feedURLString(for updater: SPUUpdater) -> String? { source?.feedURL(for: .current).absoluteString }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard workspace?.isSecurityUnlocked == true, source != nil else { throw ModelError.invalid("请先解锁 OShell 并配置更新仓库。") }
        if updateCheck != .updates && workspace?.configuration.preferences.automaticUpdateChecks != true { throw ModelError.invalid("自动检查已关闭。") }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let source, let url = item.fileURL, source.acceptsArchive(url, flavor: .current) else { throw ModelError.invalid("更新文件与当前仓库、系统或处理器架构不匹配。") }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingInstall = installHandler
        DispatchQueue.main.async { [weak self] in self?.resumeInstallation() }
        return true
    }
    func resumeInstallation() {
        guard let workspace, let handler = pendingInstall else { return }
        guard NSApp.modalWindow == nil, workspace.window?.attachedSheet == nil else {
            Dialogs.message("更新已准备好。请先关闭当前对话框，再选择“安装已下载的更新…”。"); return
        }
        guard workspace.canQuit(forUpdate: true) else { return }
        pendingInstall = nil; handler()
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { pendingInstall = nil }
}

extension WorkspaceController {
    @objc func checkForUpdates() { appUpdater.check() }
    @objc func showUpdatePreferences() { editPreferences(appearanceSelected: false, updatesSelected: true) }
}
