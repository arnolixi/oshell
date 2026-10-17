// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import OShellCore

private final class ResumeUIBackend: ResumableFileBackend {
    let description = "resume UI fixture"
    private let gate = DispatchSemaphore(value: 0)
    func connect() throws {}
    func canonicalPath(_ path: String) throws -> String { path }
    func list(_ path: String) throws -> [RemoteFileEntry] { [] }
    func upload(_ local: URL, to remote: String, progress: @escaping (UInt64, UInt64) -> Void) throws {}
    func download(_ remote: String, to local: URL, progress: @escaping (UInt64, UInt64) -> Void) throws {}
    func mkdir(_ path: String) throws {}
    func rename(_ source: String, to destination: String) throws {}
    func remove(_ path: String, directory: Bool) throws {}
    func cancel() { gate.signal() }
    func transfer(_ job: ResumableFileTransfer, progress: @escaping (UInt64, UInt64) -> Void) throws {
        if !job.ownsPartial {
            job.ownsPartial = true; progress(64,256); _ = gate.wait(timeout: .now()+10)
            throw ModelError.invalid("fixture paused")
        }
        progress(64,256); progress(256,256)
    }
}
enum FileResumeUITest {
    static func run(_ workspace: WorkspaceController) {
        RunLoop.main.add(Timer(timeInterval:0.1,repeats:false) { _ in exercise(workspace) },forMode:.common)
    }
    private static func exercise(_ workspace: WorkspaceController) {
        var checks=[String:Bool](), done=false
        let session=RemoteFileSession(workspace:workspace,backendFactory:{ _ in ResumeUIBackend() })
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oshell-resume-ui-"+UUID().uuidString)
        try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        let profile=SessionProfile(name:"resume fixture",host:"127.0.0.1")
        func views(_ v:NSView)->[NSView] { [v]+v.subviews.flatMap(views) }
        let historyView=views(session.view).compactMap { $0 as? FileTransferHistoryView }.first!
        func finish() {
            guard !done else { return };done=true;session.shutdown();try? FileManager.default.removeItem(at:root)
            let result:[String:Any]=["passed":checks.values.allSatisfy{$0},"checks":checks]
            if let path=ProcessInfo.processInfo.environment["OSHELL_FILE_RESUME_OUTPUT"] { try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path)) }
            workspace.shutdown();NSApp.terminate(nil)
        }
        func wait(_ name:String,_ predicate:@escaping()->Bool,_ body:@escaping()->Void) {
            let deadline=Date().addingTimeInterval(15)
            func poll() { guard !done else { return }; if predicate() { checks[name]=true;body() } else if Date()>deadline { checks[name]=false;finish() } else { DispatchQueue.main.asyncAfter(deadline:.now()+0.05,execute:poll) } };poll()
        }
        func entry(_ name:String)->RemoteFileEntry { .init(name:name,size:256,modified:nil,directory:false,symbolicLink:false) }
        session.toggleHistory()
        checks["emptyHistoryActionsDisabled"] = !historyView.pauseButton.isEnabled && !historyView.continueButton.isEnabled && !historyView.retryButton.isEnabled
        session.toggleHistory()
        session.connect(profile,directory:"/fixture")
        wait("connected",{session.connected && !session.hasActiveOperation}) {
            session.download([entry("a.bin"),entry("later.bin")],from:"/fixture",to:root)
            wait("pauseButtonAvailable",{historyView.pauseButton.isEnabled}) {
                let id=session.transferHistory.snapshot.first!.id
                historyView.pauseButton.performClick(nil)
                checks["pausePreservesRecord"] = session.transferHistory.snapshot.first?.state == .paused
                checks["pauseStopsRemainingBatch"] = session.transferHistory.snapshot.last?.state == .skipped
                checks["pauseShowsContinue"] = historyView.continueButton.isEnabled && !historyView.pauseButton.isEnabled
                session.transferHistory.clearCompleted()
                checks["clearDoesNotRemovePausedCheckpoint"] = session.transferHistory.snapshot.map(\.id) == [id]
                historyView.continueButton.performClick(nil)
                wait("continueReconnectsAndCompletes",{session.transferHistory.snapshot.first?.state == .succeeded && !session.hasActiveOperation}) {
                    checks["sameRecordResumed"] = session.transferHistory.snapshot.count == 1 && session.transferHistory.snapshot.first?.id == id
                    checks["resumeProgressCompletes"] = session.transferHistory.snapshot.first?.bytes == 256
                    checks["completedActionsDisabled"] = !historyView.pauseButton.isEnabled && !historyView.continueButton.isEnabled && !historyView.retryButton.isEnabled
                    session.download([entry("cancel.bin")],from:"/fixture",to:root)
                    wait("secondTransferRunning",{historyView.pauseButton.isEnabled}) {
                        let second=session.transferHistory.snapshot.last!.id
                        session.cancelFileOperation();historyView.selectRecord(second)
                        checks["cancelledRecordOffersRetry"] = historyView.retryButton.isEnabled && !historyView.continueButton.isEnabled
                        historyView.retryButton.performClick(nil)
                        wait("retryResumesAfterReconnect",{session.transferHistory.snapshot.last?.state == .succeeded && !session.hasActiveOperation}) {
                            session.view.setFrameSize(NSSize(width:776,height:450));session.view.layoutSubtreeIfNeeded()
                            checks["resumeButtonsFitMinimumWindow"] = [historyView.pauseButton,historyView.continueButton,historyView.retryButton].allSatisfy { session.view.bounds.contains($0.convert($0.bounds,to:session.view)) }
                            checks["checkpointPathShownInDetails"] = session.transferHistory.snapshot.last?.detail.contains(".oshell-part-") == true
                            finish()
                        }
                    }
                }
            }
        }
    }
}
