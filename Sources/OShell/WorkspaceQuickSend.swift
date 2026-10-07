// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

extension WorkspaceController {
    var quickSendCandidates: [TerminalPane] {
        switch quickSendScope {
        case .current: return selectedTab.map { [$0.activePane] } ?? []
        case .tab: return selectedTab?.layout.panes ?? []
        case .all: return inputPanes
        case .visible: return inputPanes.filter { $0.view.window != nil && !$0.view.isHiddenOrHasHiddenAncestor && !$0.view.visibleRect.isEmpty }
        case .selected: return inputPanes.filter { quickSendSelected.contains($0.id) }
        }
    }
    var quickSendTargets: [TerminalPane] { quickSendCandidates.filter(\.acceptsManagedInput) }
    func refreshQuickSendBar() {
        quickSendSelected.formIntersection(Set(inputPanes.map(\.id)))
        let candidates = quickSendCandidates, ready = candidates.filter(\.acceptsManagedInput)
        quickSendBar.update(scope: quickSendScope, ready: ready, skipped: candidates.count - ready.count, commands: configuration.quickCommands)
    }
    func chooseQuickSendScope(_ scope: QuickSendScope) {
        var selection = quickSendSelected
        if scope == .selected {
            let initial = quickSendSelected.isEmpty ? Set(quickSendTargets.map(\.id)) : quickSendSelected
            guard let chosen = InputDialogs.targets(inputPanes, selected: initial, title: "快速发送的目标会话") else { refreshQuickSendBar(); return }
            selection = chosen
        }
        if configuration.preferences.quickSendScope != scope {
            var value = configuration; value.preferences.quickSendScope = scope
            guard saveConfiguration(value) else { refreshQuickSendBar(); return }
        }
        quickSendSelected = selection
        quickSendScope = scope; refreshQuickSendBar()
    }
    @discardableResult func sendQuickCommand(_ entry: QuickSendEntry) -> Bool {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard entry.text.utf8.count <= 65536, !entry.text.contains("\0") else { Dialogs.message("快速命令不能包含空字符或超过 64 KiB。"); return false }
        if InputText.isMultiline(entry.text) { composeQuickCommand(entry); return false }
        let targets = quickSendTargets
        guard !targets.isEmpty else { refreshQuickSendBar(); Dialogs.message("此范围没有可输入的终端标签。已断开的标签仍可输入；登录、传输或交互式本机工具运行中暂不可用。"); return false }
        // Explicit command dispatch is independent of synchronized keyboard input.
        let bytes = InputText.bytes(entry.text, bracketed: false, appendReturn: entry.appendReturn)
        targets.forEach { $0.sendManaged(bytes) }; refreshQuickSendBar(); return true
    }
    func composeQuickCommand(_ entry: QuickSendEntry) {
        guard entry.text.utf8.count <= 1_048_576, !entry.text.contains("\0") else { Dialogs.message("内容不能包含空字符或超过 1 MiB。"); return }
        if composer.isHidden { toggleComposer() }
        composerTargets = Set(quickSendTargets.map(\.id))
        composer.fill(QuickCommand(name: "快速发送", text: entry.text, appendReturn: entry.appendReturn))
        refreshOperatorState(); window?.makeFirstResponder(composer.editor)
    }
    @objc func toggleQuickSendBar() {
        var config = configuration; config.preferences.quickSendBarVisible.toggle()
        guard saveConfiguration(config) else { return }
        quickSendBar.isHidden = !config.preferences.quickSendBarVisible; quickSendHeight.constant = quickSendBar.isHidden ? 0 : 36
        window?.contentView?.layoutSubtreeIfNeeded()
        if quickSendBar.isHidden { selectedTab?.activePane.activate() } else { window?.makeFirstResponder(quickSendBar.field) }
    }
    @objc func focusQuickSendBar() {
        if quickSendBar.isHidden { toggleQuickSendBar() }
        if !quickSendBar.isHidden { window?.makeFirstResponder(quickSendBar.field) }
    }
}
