// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

final class FocusFullscreenTest {
    private static var retained: FocusFullscreenTest?
    private let workspace: WorkspaceController
    private var checks = [String: Bool](), finished = false
    private var originalFrame = NSRect.zero
    private var paneIDs = [UUID](), pids = [pid_t]()
    private var window: NSWindow { workspace.window! }
    init(_ workspace: WorkspaceController) { self.workspace = workspace }
    static func run(_ workspace: WorkspaceController) {
        let test = FocusFullscreenTest(workspace); retained = test
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { test.start() }
    }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func wait(_ name: String, _ condition: @escaping () -> Bool, _ action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(15)
        func poll() {
            guard !self.finished else { return }
            if condition() { self.checks[name] = true; action() }
            else if Date() > deadline { self.checks[name] = false; self.finish() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll) }
        }; poll()
    }
    private func start() {
        workspace.newLocal(); workspace.splitVertical()
        paneIDs = workspace.inputPanes.map(\.id)
        wait("localProcessesReady", { self.workspace.inputPanes.allSatisfy { $0.terminal.process.running } }) { [self] in
            pids = workspace.inputPanes.map { $0.terminal.process.shellPid }
            workspace.newBlankTab()
            originalFrame = window.frame
            let initialLinks = workspace.configuration.sessionLinks.visible
            let initialWarning = workspace.masterWarning.isHidden
            workspace.quickSendBar.fill(.init(text: "keep this draft", appendReturn: true))
            let editor = workspace.quickSendBar.field.currentEditor()
            workspace.setFocusFullscreenChrome(true)
            window.contentView?.layoutSubtreeIfNeeded()
            checks["onlyTopChromeHidden"] = workspace.topToolbar?.isHidden == true && workspace.topDivider?.isHidden == true && workspace.sessionLinkBar.isHidden && workspace.masterWarning.isHidden
            let strip = views(window.contentView!).compactMap { $0 as? TabStripView }.first { !$0.isHidden }!
            let rect = strip.convert(strip.bounds, to: window.contentView!)
            checks["tabsAtTopOfContent"] = abs(rect.maxY - window.contentView!.bounds.maxY) < 1
            checks["quickSendRemainsVisibleAndFocused"] = !workspace.quickSendBar.isHidden && editor != nil && window.firstResponder === editor
            workspace.setFocusFullscreenChrome(false)
            window.contentView?.layoutSubtreeIfNeeded()
            checks["normalChromeRestored"] = workspace.topToolbar?.isHidden == false && workspace.sessionLinkBar.isHidden == !initialLinks && workspace.masterWarning.isHidden == initialWarning
            checks["windowFrameAndDraftPreserved"] = window.frame == originalFrame && workspace.quickSendBar.field.stringValue == "keep this draft"
            checks["noSessionRestartFromChromeChange"] = workspace.inputPanes.filter { paneIDs.contains($0.id) }.map { $0.terminal.process.shellPid } == pids
            // Use real native fullscreen transitions; no direct styleMask spoofing.
            workspace.requestFocusFullscreen(true)
            wait("enteredNativeFocusFullscreen", { self.window.styleMask.contains(.fullScreen) && !self.workspace.fullscreenTransitionInProgress }) { [self] in
                checks["nativeFocusShowsOnlyTabsAndBelow"] = workspace.isFocusFullscreen && workspace.topToolbar?.isHidden == true && workspace.sessionLinkBar.isHidden
                checks["titleAndWindowButtonsHidden"] = window.titleVisibility == .hidden && [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy { window.standardWindowButton($0)?.isHidden == true }
                let options = workspace.window(window, willUseFullScreenPresentationOptions: [.fullScreen])
                checks["nativeMenuAndDockAutoHide"] = options.contains(.autoHideMenuBar) && options.contains(.autoHideDock)
                let manager = SessionManager(workspace: workspace); manager.show()
                checks["managerStaysWithFullscreenWindow"] = manager.window?.parent === window && manager.window?.collectionBehavior.contains(.fullScreenAuxiliary) == true
                if let popup = manager.window { checks["escapeDismissesPopupFirst"] = PopupKeyboard.dismiss(window: popup) && workspace.isFocusFullscreen }
                manager.close()
                // Presentation-only mode must not rewrite persistent link prefs.
                workspace.toggleSessionLinkBar()
                checks["linksStayHiddenAfterPreferenceChange"] = workspace.sessionLinkBar.isHidden
                workspace.toggleSessionLinkBar()
                let pane = workspace.selectedTab!.activePane
                pane.activate(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                let consumed = window.performKeyEquivalent(with: event)
                checks["escapeRequestsFullscreenExit"] = consumed && !workspace.focusFullscreenRequested
                if !consumed { workspace.requestFocusFullscreen(false) }
                wait("returnedToWindowedMode", { !self.window.styleMask.contains(.fullScreen) && !self.workspace.fullscreenTransitionInProgress && !self.workspace.isFocusFullscreen }) { [self] in
                    checks["exitRestoresChromeAndPreferences"] = workspace.topToolbar?.isHidden == false && workspace.configuration.sessionLinks.visible == initialLinks && workspace.sessionLinkBar.isHidden == !initialLinks
                    checks["allOriginalProcessesSurviveFullscreen"] = workspace.inputPanes.filter { paneIDs.contains($0.id) }.map { $0.terminal.process.shellPid } == pids && workspace.inputPanes.filter { paneIDs.contains($0.id) }.allSatisfy { $0.terminal.process.running }
                    checks["exitRestoresWindowSize"] = abs(window.frame.width - originalFrame.width) < 2 && abs(window.frame.height - originalFrame.height) < 2
                    // Exercise an exit request while entry animation is pending.
                    workspace.requestFocusFullscreen(true); workspace.requestFocusFullscreen(false)
                    wait("rapidEntryCancelRestoresWindow", { !self.workspace.isFocusFullscreen && !self.workspace.fullscreenTransitionInProgress && !self.window.styleMask.contains(.fullScreen) }) { [self] in finish() }
                }
            }
        }
    }
    private func finish() {
        guard !finished else { return }; finished = true
        if let path = ProcessInfo.processInfo.environment["OSHELL_FOCUS_FULLSCREEN_OUTPUT"] {
            let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "state": ["requested": workspace.focusFullscreenRequested, "active": workspace.isFocusFullscreen, "transition": workspace.fullscreenTransitionInProgress, "native": window.styleMask.contains(.fullScreen)]]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        workspace.shutdown(); NSApp.terminate(nil)
    }
}
