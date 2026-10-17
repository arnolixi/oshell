// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

enum LocalPromptEditingTest {
    static func run(_ workspace:WorkspaceController) {
        workspace.configuration.preferences.metal = false
        workspace.newBlankTab()
        let pane = workspace.selectedTab!.activePane
        workspace.window?.setContentSize(NSSize(width:800,height:500))
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        var checks=[String:Bool]()
        func send(_ value:String) { pane.handleEndedInput(Array(value.utf8)[...]) }
        let model=pane.terminal.getTerminal(), prompt=EndedSessionInput.prompt.count
        func line()->String { model.getCursorLineText().trimmingCharacters(in:.whitespaces) }
        send("hep"); send("\u{1}")
        checks["controlAGoesAfterPrompt"] = model.buffer.x == prompt
        send("\u{5}"); checks["controlEGoesToEnd"] = model.buffer.x == prompt+3
        send("\u{1b}[Dl")
        checks["middleInsertionRendersCorrectly"] = line() == "OShell > help" && model.buffer.x == prompt+3
        send("\r"); checks["helpExecutesEditedLine"] = String(decoding:model.getBufferAsData(),as:UTF8.self).contains("DNS")
        send("draft\u{1b}[A");checks["upRecallsHistory"] = line() == "OShell > help"
        send("\u{1b}[B");checks["downRestoresDraft"] = line() == "OShell > draft"
        send("\u{3}中文👩🏽‍💻")
        send("\u{7f}");checks["backspaceRemovesWholeEmoji"] = line() == "OShell > 中文"
        send("\u{1b}[D");checks["leftMovesOneWideCharacter"] = model.buffer.x == prompt+2
        send("国");checks["unicodeMiddleInsertion"] = line() == "OShell > 中国文"
        send("\u{1b}[3~");checks["deleteRemovesForwardCharacter"] = line() == "OShell > 中国"
        send("\u{3}")
        let beforeY = model.buffer.y, beforeDisp = model.buffer.yDisp
        send(String(repeating:"a",count:300))
        checks["longDraftStaysOnOneRow"] = model.buffer.y == beforeY && model.buffer.yDisp == beforeDisp && model.buffer.x < model.cols-1
        send("\u{1}ping ");checks["longDraftHomeIsVisible"] = line().hasPrefix("OShell > ping ") && model.buffer.x == prompt+5
        send("\u{5}");checks["longDraftEndStillOnOneRow"] = model.buffer.y == beforeY && model.buffer.x < model.cols-1
        send("\u{3}\u{1b}OA");checks["applicationCursorKeysRecall"] = line() == "OShell > help"
        send("\u{1b}OB");checks["applicationCursorKeysRestoreEmptyDraft"] = line() == "OShell >"
        send("draft\u{2}")
        // Exercise actual AppKit key translation, not only pre-translated bytes.
        workspace.window?.makeFirstResponder(pane.terminal)
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                       timestamp: 0, windowNumber: workspace.window?.windowNumber ?? 0,
                                       context: nil, characters: "\u{12}", charactersIgnoringModifiers: "r",
                                       isARepeat: false, keyCode: 15) { pane.terminal.keyDown(with: event) }
        checks["controlRKeyStartsSearch"] = line().contains("reverse-i-search")
        send("he"); checks["searchDisplaysQueryAndMatch"] = line().contains("`he': help")
        checks["searchDoesNotExecute"] = !pane.isRunningLocalTool
        send("\u{7}"); checks["searchCancelRestoresDraftCursor"] = line() == "OShell > draft" && model.buffer.x == prompt+4
        send("\u{3}\u{12}help\u{1b}")
        checks["escapeAcceptsWithoutExecuting"] = line() == "OShell > help" && !pane.isRunningLocalTool
        send("X"); checks["typingAfterSearchEscapeIsPreserved"] = line() == "OShell > helpX"
        send("\u{3}\u{12}unmatched\r")
        checks["failedSearchDoesNotExecute"] = line().contains("failed reverse-i-search") && !pane.isRunningLocalTool
        send("\u{7}\u{3}one two\u{17}")
        checks["killPreviousWord"] = line() == "OShell > one"
        send("\u{19}"); checks["yankWord"] = line() == "OShell > one two"
        send("\u{3}ss\t"); checks["commandNameCompletion"] = line() == "OShell > ssh"
        send("\u{c}"); checks["clearScreenPreservesDraft"] = line() == "OShell > ssh" && model.buffer.y == 0
        send("\u{3}\u{12}"+String(repeating:"中",count:100))
        checks["longSearchStaysOnOneRow"] = model.buffer.x < model.cols-1 && line().contains("failed reverse-i-search")
        send("\u{7}\u{3}")
        workspace.newBlankTab()
        let other=workspace.selectedTab!.activePane
        other.handleEndedInput(Array("\u{1b}[A".utf8)[...])
        checks["historyIsPerPane"] = other.terminal.getTerminal().getCursorLineText().trimmingCharacters(in:.whitespaces) == "OShell >"
        checks["editingDidNotLaunchTool"] = !pane.isRunningLocalTool && !other.isRunningLocalTool
        let report:[String:Any]=["passed":checks.values.allSatisfy { $0 },"checks":checks]
        if let path=ProcessInfo.processInfo.environment["OSHELL_LOCAL_PROMPT_OUTPUT"] { try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path)) }
        workspace.shutdown();NSApp.terminate(nil)
    }
}
