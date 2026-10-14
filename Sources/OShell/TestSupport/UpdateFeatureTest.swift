// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum UpdateFeatureTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) } }
        do {
            try workspace.appUpdater.configure()
            checks["emptyRepositoryDoesNotStartUpdater"] = !workspace.appUpdater.started
            let items = NSApp.mainMenu.map(menuItems) ?? []
            checks["checkMenuExists"] = items.contains { $0.action == #selector(WorkspaceController.checkForUpdates) }
            checks["settingsMenuExists"] = items.contains { $0.action == #selector(WorkspaceController.showUpdatePreferences) }
            let view = UpdateSettingsView(preferences: workspace.configuration.preferences)
            checks["automaticChecksDefaultOff"] = view.automatic.state == .off
            view.repository.stringValue = "http://github.com/example/project"
            checks["invalidSourceRejected"] = (try? view.values(updating: workspace.configuration.preferences)) == nil
            view.repository.stringValue = "https://github.com/example/project.git"
            let parsed = try view.values(updating: workspace.configuration.preferences)
            checks["repositoryURLNormalized"] = parsed.updateRepository == "example/project"
            view.repository.stringValue = ""; view.automatic.state = .on
            checks["automaticChecksRequireRepository"] = (try? view.values(updating: workspace.configuration.preferences)) == nil
            var timer = Timer(timeInterval: 0.03, repeats: true) { _ in
                if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) }
            }
            RunLoop.main.add(timer, forMode: .modalPanel); let before = workspace.configurationRevision
            workspace.checkForUpdates(); timer.invalidate()
            checks["unconfiguredCheckOpensCancellableSettings"] = workspace.configurationRevision == before && !workspace.appUpdater.started
            let defaultsDomain = (Bundle.main.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String ?? Bundle.main.bundleIdentifier!) as CFString
            CFPreferencesSetAppValue("SUFeedURL" as CFString, "https://example.invalid/old-appcast.xml" as CFString, defaultsDomain)
            CFPreferencesAppSynchronize(defaultsDomain)
            var edited = false
            timer = Timer(timeInterval: 0.03, repeats: true) { _ in
                guard !edited, let root = NSApp.modalWindow?.contentView else { return }
                guard let field = views(root).first(where: { $0.identifier?.rawValue == "updates.repository" }) as? NSTextField else { return }
                field.stringValue = "example/project"; edited = true
                views(root).compactMap { $0 as? NSButton }.first { $0.title == "应用" }?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .modalPanel); workspace.showUpdatePreferences(); timer.invalidate()
            checks["settingsPersisted"] = try workspace.store.load().preferences.updateRepository == "example/project"
            checks["oldFeedOverrideCleared"] = CFPreferencesCopyAppValue("SUFeedURL" as CFString, defaultsDomain) == nil
            checks["checksUseStaticPages"] = try UpdateSource("example/project").staticMetadataURL.absoluteString == "https://example.github.io/project/updates/latest.json"
            checks["configuredManualUpdaterStarts"] = workspace.appUpdater.started && !workspace.appUpdater.isBusy
            workspace.newLocal(); let pane = workspace.selectedTab!.activePane, pid = pane.terminal.process.shellPid
            timer = Timer(timeInterval: 0.03, repeats: true) { _ in if let window = NSApp.modalWindow { _ = PopupKeyboard.dismiss(window: window) } }
            RunLoop.main.add(timer, forMode: .modalPanel); let quit = workspace.canQuit(forUpdate: true); timer.invalidate()
            checks["cancelUpdateQuitPreservesLiveSession"] = !quit && !pane.isShutdown && pane.terminal.process.shellPid == pid && pane.terminal.process.running
            checks["signedArchivesAndFeedsRequired"] = Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true && Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true
            checks["automaticInstallationDisabled"] = Bundle.main.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool == false
        } catch { checks["unexpectedError"] = false; print(error.localizedDescription) }
        let path = ProcessInfo.processInfo.environment["OSHELL_UPDATE_FEATURE_OUTPUT"] ?? "/tmp/oshell-update-feature.json"
        try? JSONSerialization.data(withJSONObject: ["passed": checks.values.allSatisfy { $0 }, "checks": checks], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path))
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
