// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import OShellCore

enum QuickSendGroupsTest {
    static func run(_ workspace: WorkspaceController) {
        var checks = [String: Bool]()
        let bar = workspace.quickSendBar
        func ids() -> Set<UUID> { Set(workspace.quickSendTargets.map(\.id)) }
        func text(_ pane: TerminalPane) -> String { String(decoding: pane.terminal.getTerminal().getBufferAsData(), as: UTF8.self) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func choose(_ groups: Set<UUID>?, label: String) {
            let timer = Timer(timeInterval: 0.04, repeats: false) { _ in
                guard let window = NSApp.modalWindow, let root = window.contentView else { checks[label + "Modal"] = false; return }
                let buttons = descendants(root).compactMap { $0 as? NSButton }
                let controls = buttons.filter { $0.identifier?.rawValue.hasPrefix("quickSend.group.") == true }
                checks[label + "ListsAllGroups"] = controls.count == workspace.quickSendGroups.count
                if let groups {
                    for button in controls { button.state = groups.contains(where: { button.identifier?.rawValue == "quickSend.group." + $0.uuidString }) ? .on : .off }
                    buttons.first { $0.title == "确定" }?.performClick(nil)
                } else { checks[label + "EscapeCloses"] = PopupKeyboard.dismiss(window: window) }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .init("NSModalPanelRunLoopMode"))
            workspace.chooseQuickSendScope(.selectedGroups)
        }
        do {
            workspace.newBlankTab(); let a = workspace.selectedTab!, pa = a.activePane
            workspace.newBlankTab(); let b = workspace.selectedTab!, pb = b.activePane
            workspace.chooseQuickSendScope(.currentGroup)
            checks["unpartitionedTabsShareDefaultGroup"] = ids() == Set([pa.id, pb.id])
            checks["currentGroupModePersists"] = (try? workspace.store.load().preferences.quickSendScope) == .currentGroup
            let firstGroup = try workspace.createTabGroup(name: "生产", activate: false)
            let secondGroup = try workspace.createTabGroup(name: "测试", activate: false)
            _ = workspace.moveTab(a.id, toGroup: firstGroup.id); _ = workspace.moveTab(b.id, toGroup: firstGroup.id)
            workspace.newBlankTab(); let c = workspace.selectedTab!, pc = c.activePane
            _ = workspace.moveTab(c.id, toGroup: secondGroup.id)
            workspace.select(a)
            checks["currentGroupIncludesInactiveTabs"] = ids() == Set([pa.id, pb.id])
            checks["currentGroupNameInCaption"] = bar.scopeButton.menu?.items.first?.title.contains("生产") == true
            checks["menuOffersBothGroupScopes"] = [QuickSendScope.currentGroup, .selectedGroups].allSatisfy { scope in bar.scopeButton.menu?.items.contains { $0.tag == scope.rawValue && $0.title == scope.title } == true }
            bar.fill(.init(text: "GROUP_A_MARKER", appendReturn: true)); bar.submit()
            checks["currentGroupReceivesCommand"] = [pa, pb].allSatisfy { text($0).contains("GROUP_A_MARKER") }
            checks["otherGroupDoesNotReceiveCommand"] = !text(pc).contains("GROUP_A_MARKER")
            workspace.select(c)
            checks["currentGroupFollowsSelection"] = ids() == [pc.id]
            let revision = workspace.configurationRevision
            choose(nil, label: "cancel")
            checks["cancelRetainsScopeAndTargets"] = workspace.quickSendScope == .currentGroup && ids() == [pc.id] && workspace.configurationRevision == revision
            workspace.setTabGroupHidden(firstGroup.id, hidden: true)
            choose([firstGroup.id], label: "hidden")
            checks["selectedHiddenGroupTargetsAllMembers"] = ids() == Set([pa.id, pb.id]) && firstGroup.isHidden
            checks["hiddenGroupInTooltip"] = bar.scopeButton.toolTip?.contains("生产（隐藏）") == true
            workspace.select(c)
            checks["selectedGroupsIndependentOfActiveTab"] = ids() == Set([pa.id, pb.id])
            bar.fill(.init(text: "HIDDEN_GROUP_MARKER", appendReturn: true)); bar.submit()
            checks["hiddenGroupCommandDelivered"] = [pa, pb].allSatisfy { text($0).contains("HIDDEN_GROUP_MARKER") } && !text(pc).contains("HIDDEN_GROUP_MARKER")
            checks["sendDoesNotRevealHiddenGroup"] = firstGroup.isHidden
            let editor = bar.field.currentEditor()
            checks["sendRetainsQuickFieldFocus"] = editor != nil && workspace.window?.firstResponder === editor
            workspace.newBlankTab(); let d = workspace.selectedTab!, pd = d.activePane
            _ = workspace.moveTab(d.id, toGroup: firstGroup.id)
            checks["newMemberAutomaticallyIncluded"] = ids() == Set([pa.id, pb.id, pd.id])
            _ = workspace.moveTab(b.id, toGroup: secondGroup.id)
            checks["movedMemberAutomaticallyExcluded"] = ids() == Set([pa.id, pd.id])
            try workspace.renameTabGroup(firstGroup.id, name: "生产新")
            checks["renamePreservesSelectionAndRefreshesTooltip"] = workspace.quickSendSelectedGroups == [firstGroup.id] && bar.scopeButton.toolTip?.contains("生产新（隐藏）") == true
            choose([firstGroup.id, secondGroup.id], label: "multiple")
            checks["multipleGroupsUnionWithoutDuplicates"] = ids() == Set([pa.id, pb.id, pc.id, pd.id]) && workspace.quickSendTargets.count == 4
            checks["selectedGroupsModePersists"] = (try? workspace.store.load().preferences.quickSendScope) == .selectedGroups
            let restored = WorkspaceController(store: workspace.store)
            restored.newBlankTab()
            checks["restartRemembersModeWithoutStaleGroups"] = restored.quickSendScope == .selectedGroups && restored.quickSendSelectedGroups.isEmpty && restored.quickSendTargets.isEmpty
            restored.shutdown(); restored.window?.close()
            workspace.chooseQuickSendScope(.current)
            choose([firstGroup.id], label: "selectAgain")
            checks["windowSelectionSurvivesScopeChanges"] = workspace.quickSendSelectedGroups == [firstGroup.id]
            workspace.dissolveTabGroup(firstGroup.id)
            checks["deletedGroupDoesNotFallBackToAll"] = workspace.quickSendSelectedGroups.isEmpty && workspace.quickSendTargets.isEmpty && workspace.quickSendScope == .selectedGroups
            checks["emptySelectionDisablesSend"] = descendants(bar).compactMap { $0 as? NSButton }.first { $0.title == "发送" }?.isEnabled == false
            let empty = try workspace.createTabGroup(name: "空分组")
            workspace.chooseQuickSendScope(.currentGroup)
            checks["emptyActiveGroupDoesNotTargetAnotherGroup"] = workspace.currentQuickSendGroupID == empty.id && workspace.quickSendTargets.isEmpty
            choose([empty.id], label: "empty")
            workspace.newBlankTab(); let endA = workspace.selectedTab!
            workspace.newBlankTab(); let endB = workspace.selectedTab!
            checks["selectedEmptyGroupIncludesLaterTabs"] = ids() == Set([endA.activePane.id, endB.activePane.id])
            bar.fill(.init(text: "exit", appendReturn: true)); bar.submit()
            checks["groupExitClosesOnlySelectedGroupTabs"] = !workspace.tabs.contains { $0 === endA || $0 === endB } && workspace.tabs.contains { $0 === c }
            checks["groupExitRetainsInputFocus"] = bar.field.currentEditor() != nil && workspace.window?.firstResponder === bar.field.currentEditor()
        } catch { checks["unexpectedError"] = false; print(error.localizedDescription) }
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let path = ProcessInfo.processInfo.environment["OSHELL_QUICKSEND_GROUPS_OUTPUT"] { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)) }
        print(report); workspace.shutdown(); NSApp.terminate(nil)
    }
}
