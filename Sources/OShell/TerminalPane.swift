// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import SwiftTerm
import OShellCore

final class OShellTerminal: LocalProcessTerminalView {
    weak var owner: TerminalPane?
    private var userInputDepth = 0
    override func layout() { super.layout(); owner?.resizeLocalTool() }
    override func keyDown(with event: NSEvent) { userInputDepth += 1; defer { userInputDepth -= 1 }; super.keyDown(with: event) }
    override func keyUp(with event: NSEvent) { userInputDepth += 1; defer { userInputDepth -= 1 }; super.keyUp(with: event) }
    override func insertText(_ string: Any, replacementRange: NSRange) { userInputDepth += 1; defer { userInputDepth -= 1 }; super.insertText(string, replacementRange: replacementRange) }
    override func paste(_ sender: Any) { if let text = NSPasteboard.general.string(forType: .string), let owner { owner.onPaste?(owner, text) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) {
        if let arrangement = enclosingScrollView as? TabArrangementView {
            let model = getTerminal()
            let horizontalGesture = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            let reportsMouse = allowMouseReporting && model.mouseMode != .off
                && (!event.modifierFlags.contains(.shift) || model.mouseShiftCapture)
            let canScrollHistory = canScroll && (event.scrollingDeltaY > 0 ? scrollPosition > 0 : scrollPosition < 1)
            // Option explicitly scrolls the arrangement even over terminal
            // history or a mouse-reporting TUI. Otherwise preserve vertical
            // terminal scrolling until its history reaches the relevant edge.
            if event.modifierFlags.contains(.option) || horizontalGesture
                || (!reportsMouse && !model.isCurrentBufferAlternate && !canScrollHistory) {
                if arrangement.scrollArrangement(with: event) { return }
            }
        }
        super.scrollWheel(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        guard owner?.isShutdown == false, let window else { return }
        if window.firstResponder !== self { _ = window.makeFirstResponder(self) }
        // Keep SwiftTerm's selection, links and remote mouse reporting intact.
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        owner?.searchPanel.selectionChanged()
        copySelectedTextIfEnabled()
    }
    override func selectAll(_ sender: Any?) { super.selectAll(sender); owner?.searchPanel.selectionChanged(); copySelectedTextIfEnabled() }
    private func copySelectedTextIfEnabled() {
        if owner?.copyOnSelect == true, selection.active {
            let text = selection.getSelectedText()
            if !text.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        if owner?.rightClickPaste == true && !event.modifierFlags.contains(.shift) { window?.makeFirstResponder(self); paste(self) }
        else { super.rightMouseDown(with: event) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        owner?.profile.kind == .ssh && owner?.ended == false && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let owner, !owner.ended, owner.profile.kind == .ssh, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        owner.onFilesDropped?(owner, urls); return true
    }
    override func performFindPanelAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        switch item.tag {
        case Int(NSFindPanelAction.next.rawValue): owner?.searchPanel.navigate(next: true)
        case Int(NSFindPanelAction.previous.rawValue): owner?.searchPanel.navigate(next: false)
        default: owner?.searchPanel.show()
        }
    }
    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let action = NSTextFinder.Action(rawValue: item.tag) else { return }
        switch action {
        case .nextMatch: owner?.searchPanel.navigate(next: true)
        case .previousMatch: owner?.searchPanel.navigate(next: false)
        case .hideFindInterface: owner?.searchPanel.hide()
        case .showFindInterface, .setSearchString: owner?.searchPanel.show()
        default: break
        }
    }
    override func dataReceived(slice: ArraySlice<UInt8>) { owner?.receive(Data(slice)) }
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard owner?.isShutdown != true else { return }
        if let owner, owner.ended {
            if userInputDepth > 0, owner.onUserInput?(owner, Array(data)) == true { return }
            owner.handleEndedInput(data, queueIfExited: userInputDepth > 0); return
        }
        if owner?.isTransferring == true {
            if data.contains(3) { owner?.cancelTransfer() }
            return
        }
        if userInputDepth > 0, let owner, owner.onUserInput?(owner, Array(data)) == true { return }
        if userInputDepth > 0 { owner?.noteUserInput(data) }
        owner?.noteActivity()
        super.send(source: source, data: data)
    }
    override func becomeFirstResponder() -> Bool {
        let success = super.becomeFirstResponder()
        if success, let owner { owner.onFocus?(owner) }
        return success
    }
    override func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
        guard let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    // Remote OSC 52 requests never silently read or replace the user's clipboard.
    override func clipboardCopy(source: TerminalView, content: Data) {}
    override func clipboardRead(source: TerminalView) -> Data? { nil }
}

final class TerminalPane: NSObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    private(set) var profile: SessionProfile
    let terminal: OShellTerminal
    let view = NSView()
    private let header = NSTextField(labelWithString: "")
    let transferProgress = ZmodemProgressView()
    let searchPanel = TerminalSearchPanel()
    private var detector = ZmodemDetector()
    private var logger: SessionLogger?
    private var transfer: ZmodemTransfer?
    private var selectionPending = false
    private var selectionBytes = Data()
    private var chooser: NSOpenPanel?
    private var transferToken = UUID()
    private var cancellationDeadline: UInt64 = 0
    private var finishingTransfer = false
    private var remoteReady = false
    private var finishMessage = ""
    private var abortDrain: AbortDrain?
    private var ignoreOutput = false
    private(set) var started = false
    private(set) var ended = false
    private(set) var isShutdown = false
    private(set) var receivedBytes: UInt64 = 0
    private var outputActivity = OutputActivity()
    private(set) var hasUnreadOutput = false
    func markOutputUnread() { hasUnreadOutput = true }
    func markOutputRead() { hasUnreadOutput = false }
    private var preferences: Preferences
    private let knownHostsFile: URL?
    private var authBroker: AuthBroker?
    private var oneTimePassword: String?
    let externalTerminalType: String?
    private(set) var sshConnectionGroup: SSHConnectionGroup?
    let reusesSSHConnection: Bool
    let isBlank: Bool
    var transferSelection: ((TransferDirection) -> (files: [URL], directory: URL?)?)?
    var onFocus: ((TerminalPane) -> Void)?
    var onState: (() -> Void)?
    var onOutput: ((TerminalPane) -> Void)?
    var onError: ((String) -> Void)?
    var onCloseRequested: ((TerminalPane) -> Void)?
    var onUserInput: ((TerminalPane, [UInt8]) -> Bool)?
    var onPaste: ((TerminalPane, String) -> Void)?
    var credentialsForConnection: (() -> SessionProfile)?
    var onSaveAuthenticatedPassword: ((SessionProfile, String, SSHIdentity) -> Void)? { didSet { authBroker?.onSavePassword = onSaveAuthenticatedPassword } }
    var onFilesDropped: ((TerminalPane, [URL]) -> Void)?
    private(set) var remoteDirectory = "."
    var copyOnSelect: Bool { preferences.copyOnSelect }
    var rightClickPaste: Bool { preferences.rightClickPaste }
    var acceptsManagedInput: Bool {
        !isShutdown && !blocksManagedToolInput && (ended || (started && terminal.process.running && !isTransferring && (profile.kind == .local || sessionReady)))
    }
    func sendManaged(_ bytes: [UInt8]) {
        guard acceptsManagedInput else { return }
        if ended { handleEndedInput(bytes[...]); return }
        noteUserInput(bytes[...])
        noteActivity(); terminal.process.send(data: bytes[...])
    }
    private var highlightSet: HighlightSet?
    func applyHighlights(_ set: HighlightSet?) {
        guard !isShutdown else { return }
        highlightSet = set
        guard let set else { terminal.foregroundHighlightProvider = nil; return }
        let matcher = HighlightMatcher(set: set, hostname: remoteHostname ?? title)
        terminal.foregroundHighlightProvider = { text in matcher.matches(in: text).compactMap { match in NSColor(hex: match.color).map { (match.range, $0) } } }
    }
    private var endedInput: EndedSessionInput?
    private var localTool: LocalToolProcess?
    private var pendingLocalInput = [UInt8]()
    var localToolName: String? { localTool?.command.name }
    var localToolPID: pid_t { localTool?.pid ?? 0 }
    var isRunningLocalTool: Bool { localTool != nil }
    var hasActiveProcess: Bool { !ended || isRunningLocalTool }
    var usesPTYInput: Bool { !ended || isRunningLocalTool }
    var blocksManagedToolInput: Bool { localTool.map { !$0.permitsManagedInput } ?? false }
    var transferDiagnosticState: String { transfer?.diagnosticState ?? "no helper; finishing=\(finishingTransfer)" }
    var isTransferring: Bool { selectionPending || transfer != nil || finishingTransfer }
    var isLogging: Bool { logger != nil }
    private var remoteHostname: String?
    private(set) var remoteAddress: String?
    private var hostAliases = Set<String>()
    private var knownLocalHostnames = Set<String>()
    private var currentHostHint: String?
    private var hostEpoch = 0
    private var attemptedHostEpoch: Int?
    private var hostProbeWork: DispatchWorkItem?
    private var hostProbeTimeout: DispatchWorkItem?
    private var hostProbeToken: String?
    private var hostProbeEpoch = 0
    private var hostProbeEcho: HostProbeEcho?
    private(set) var hasShellIntegration = false
    private var integratedPromptPending = false
    var allowsActiveHostProbe: Bool { profile.titleMode == .activeProbe && !hasShellIntegration }
    private var userEditingLine = false
    private var initialRemoteHostname: String?
    private var canBindInitialHost = true
    private var retiredPrimaryOutput = false
    private var lastPromptText = ""
    private var promptScan: DispatchWorkItem?
    private var idleTimer: DispatchSourceTimer?
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private(set) var sessionReady = false
    var title: String { if isBlank && !isRunningLocalTool { return "空白标签页" }; return remoteHostname ?? "主机待识别" }
    var connectionDetails: String {
        func display(_ value: String) -> String {
            String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(256))
        }
        var lines = ["当前主机", "主机名：" + title, "主机 IP：" + (remoteAddress ?? "未获取"), "识别方式：" + profile.titleMode.title]
        if profile.kind == .ssh {
            lines += ["", ended ? "原 SSH 连接（已结束）" : "初始 SSH 连接", "会话：" + display(profile.name),
                      "配置地址：" + display(profile.host), "端口：\(profile.port)", "用户名：" + (profile.username.isEmpty ? "使用 SSH 默认配置" : display(profile.username))]
            if let peer = sshConnectionGroup?.transportPeer {
                lines += ["实际连接 IP：" + peer.address, "实际连接端口：\(peer.port)"]
            } else { lines.append("实际连接 IP：未获取") }
            lines.append("实际连接指本机 TCP 对端；代理、跳板机及内层跳转可能与当前主机不同。")
            if profile.proxy.kind != .none {
                lines.append("代理：" + profile.proxy.kind.title + " · " + display(profile.proxy.host) + ":\(profile.proxy.port)")
            } else if !profile.jumpHost.isEmpty { lines.append("跳板机：" + display(profile.jumpHost)) }
            lines.append("状态：" + (ended ? "已结束，当前为本机工具模式" : (sessionReady ? "已连接" : "连接中")))
        } else { lines += ["", "本地终端", "会话：" + display(profile.name)] }
        return lines.joined(separator: "\n")
    }
    private func observeTransportPeer() {
        let pid = terminal.process.shellPid
        guard pid > 0, let group = sshConnectionGroup else { return }
        DispatchQueue.global(qos: .utility).async { [weak self, weak group] in
            let peer = SSHTransportPeer.observe(process: pid)
            DispatchQueue.main.async { [weak self, weak group] in
                guard let self, !self.isShutdown, !self.ended, self.terminal.process.shellPid == pid, let group else { return }
                group.transportPeer = peer; self.refreshHeader(); self.onState?()
            }
        }
    }
    private var interactiveTool: LocalToolProcess? {
        guard let localTool, ["ssh", "telnet"].contains(localTool.command.name), !localTool.exited else { return nil }
        return localTool
    }
    private var observesHostIdentity: Bool { !isShutdown && !retiredPrimaryOutput && (!ended || interactiveTool != nil) }
    private var identityShellReady: Bool {
        if let tool = interactiveTool { return tool.pid > 0 }
        return !ended && terminal.process.running && (profile.kind == .local || sessionReady)
    }
    private func resetHostIdentity() {
        hasShellIntegration = false; integratedPromptPending = false
        hostEpoch += 1; hostAliases = []; currentHostHint = nil; remoteHostname = nil; remoteAddress = nil
        attemptedHostEpoch = nil; lastPromptText = ""; userEditingLine = false
        hostProbeWork?.cancel(); hostProbeWork = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil
        hostProbeToken = nil; hostProbeEcho = nil; promptScan?.cancel(); promptScan = nil
    }
    private func useLocalHostIdentity() {
        knownLocalHostnames.formUnion(LocalHostIdentity.hostnameSnapshot().aliases)
        resetHostIdentity(); applyHostIdentity(LocalHostIdentity.current())
    }
    private func identityOutput(_ bytes: Data) -> Data {
        guard var echo = hostProbeEcho else { return bytes }
        let visible = echo.consume(bytes); hostProbeEcho = echo.finished ? nil : echo
        return visible
    }
    func noteActivity() { lastActivity = ProcessInfo.processInfo.systemUptime }
    var canEditLiveKeepAlive: Bool { !isShutdown && !ended && profile.kind == .ssh && terminal.process.running && sessionReady }
    func applyIdleKeepAlive(_ settings: KeepAliveSettings) throws {
        guard canEditLiveKeepAlive else { throw ModelError.invalid("当前 SSH 连接尚未就绪或已结束，无法即时应用。"); }
        let updated = try profile.keepAlive.replacingIdle(with: settings)
        idleTimer?.cancel(); idleTimer = nil
        profile.keepAlive = updated
        // Applying is user activity: the new idle interval starts now.
        noteActivity(); startIdleTimer(); onState?()
    }
    private func startIdleTimer() {
        guard !ended, !isShutdown, profile.kind == .ssh, profile.keepAlive.idleEnabled, idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Double(profile.keepAlive.idleInterval), repeating: min(5, Double(profile.keepAlive.idleInterval)), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.sendIdleIfNeeded() }
        timer.resume(); idleTimer = timer
    }
    func sendIdleIfNeeded(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard sessionReady, !ended, terminal.process.running, !isTransferring, !userEditingLine,
              !terminal.getTerminal().isCurrentBufferAlternate,
              !RemoteHostIdentity.isAuthenticationPrompt(terminal.getTerminal().getCursorLineText()),
              profile.keepAlive.idleEnabled, hostProbeToken == nil, now - lastActivity >= Double(profile.keepAlive.idleInterval),
              let bytes = try? profile.keepAlive.idleBytes() else { return }
        terminal.process.send(data: bytes[...]); noteActivity()
    }
    var renderDescription: String { terminal.isUsingMetalRenderer ? "Metal" : "CoreGraphics" }
    init(profile: SessionProfile, preferences: Preferences, knownHostsFile: URL? = nil, oneTimePassword: String? = nil, terminalType: String? = nil, connectionGroup: SSHConnectionGroup? = nil, reuseConnection: Bool = false, blank: Bool = false) {
        self.profile = profile; self.preferences = preferences; self.isBlank = blank
        self.oneTimePassword = oneTimePassword; self.externalTerminalType = terminalType
        self.sshConnectionGroup = connectionGroup ?? (profile.kind == .ssh ? try? SSHConnectionGroup(profile: profile) : nil); self.reusesSSHConnection = reuseConnection
        self.knownHostsFile = knownHostsFile
        let options = TerminalOptions(cols: 100, rows: 30, cursorStyle: .steadyBlock, scrollback: preferences.scrollback,
                                      enableSixelReported: false, kittyImageCacheLimitBytes: 4 * 1024 * 1024)
        terminal = OShellTerminal(frame: NSRect(x: 0, y: 0, width: 900, height: 580),
                                  font: Self.font(preferences), options: options)
        super.init()
        sshConnectionGroup?.attach(id)
        terminal.owner = self; terminal.processDelegate = self
        terminal.registerForDraggedTypes([.fileURL])
        view.wantsLayer = true; view.layer?.cornerRadius = 7; view.layer?.masksToBounds = true
        header.font = .systemFont(ofSize: 11, weight: .medium); header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingMiddle
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchPanel.terminal = terminal; searchPanel.onClose = { [weak self] in self?.searchPanel.hide() }
        terminal.getTerminal().registerOscHandler(code: 777) { [weak self] bytes in self?.receiveShellIdentity(bytes) }
        transferProgress.cancelButton.target = self; transferProgress.cancelButton.action = #selector(cancelAction)
        let headerBar = NSStackView(views: [header])
        headerBar.detachesHiddenViews = true
        headerBar.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(focusHeader)))
        headerBar.orientation = .horizontal; headerBar.spacing = 8
        [headerBar, searchPanel, terminal, transferProgress].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            headerBar.topAnchor.constraint(equalTo: view.topAnchor), headerBar.heightAnchor.constraint(equalToConstant: 22),
            searchPanel.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            searchPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor), searchPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transferProgress.topAnchor.constraint(equalTo: terminal.topAnchor, constant: 8),
            transferProgress.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            transferProgress.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            terminal.topAnchor.constraint(equalTo: searchPanel.bottomAnchor), terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4)
        ])
        let progressWidth = transferProgress.widthAnchor.constraint(equalToConstant: 360)
        progressWidth.priority = .defaultHigh; progressWidth.isActive = true
        apply(preferences)
        if profile.kind == .local { useLocalHostIdentity() }
        if blank { ended = true; beginEndedInput() }
        refreshHeader()
    }
    func apply(_ prefs: Preferences) {
        guard !isShutdown else { return }
        preferences = prefs
        terminal.font = Self.font(prefs)
        terminal.privateUseFallbackFont = TerminalSymbolFont.matching(terminal.font)
        terminal.changeScrollback(prefs.scrollback)
        searchPanel.bufferDidChange(resized: true)
        let scheme = prefs.colorScheme
        scheme.apply(to: terminal)
        view.layer?.backgroundColor = NSColor(hex: scheme.background)!.cgColor
        header.textColor = NSColor(hex: scheme.foreground)!.withAlphaComponent(0.75)
        transferProgress.appearance = NSAppearance(named: scheme.isDark ? .oshellDark : .aqua)
        searchPanel.appearance = transferProgress.appearance
        if !prefs.metal || terminal.window != nil { try? terminal.setUseMetal(prefs.metal) }
    }
    private static func font(_ prefs: Preferences) -> NSFont {
        if prefs.fontName.hasPrefix("DejaVuSansMono") { BundledTerminalFonts.register() }
        if !prefs.fontName.isEmpty, let font = NSFont(name: prefs.fontName, size: prefs.fontSize) { return font }
        return .oshellMonospacedSystemFont(ofSize: prefs.fontSize, weight: .regular)
    }
    func setSelected(_ value: Bool) {
        view.layer?.borderWidth = value ? 1.5 : 0
        view.layer?.borderColor = NSColor.oshellAccentColor.cgColor
    }
    @objc private func focusHeader() { activate() }
    func prepareForDisplay() {
        guard !isShutdown else { return }
        if preferences.metal, !terminal.isUsingMetalRenderer {
            do { try terminal.setUseMetal(true) } catch { onError?("Metal 初始化失败，已使用原生软件渲染：\(error.localizedDescription)") }
        }
        terminal.needsDisplay = true
        if !started && !ended { start() }
    }
    func activate() {
        guard !isShutdown else { return }
        prepareForDisplay()
        terminal.window?.makeFirstResponder(terminal)
    }
    func start() {
        do {
            var args = profile.kind == .ssh ? try profile.sshArguments(knownHostsFile: knownHostsFile, proxyHelper: ZmodemTransfer.helperDirectory.appendingPathComponent("OShellProxy")) : ["-l"]
            if let group = sshConnectionGroup { args = try group.arguments(for: profile, clone: reusesSSHConnection) + args }
            if profile.kind == .ssh && !reusesSSHConnection {
                let helper = ZmodemTransfer.helperDirectory.appendingPathComponent("OShellAskpass").path.replacingOccurrences(of: "%", with: "%%")
                args.insert(contentsOf: ["-o", "PermitLocalCommand=yes", "-o", "LocalCommand=" + ConnectionValidation.quote(helper) + " --session-ready"], at: args.count - 2)
            }
            let detachedSSH = profile.kind == .ssh && OpenSSHCapabilities.current.needsLegacyAskpass
            let executable = profile.kind == .ssh ? (detachedSSH ? ZmodemTransfer.helperDirectory.appendingPathComponent("OShellSSH").path : "/usr/bin/ssh") : "/bin/zsh"
            started = true; ended = false
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = externalTerminalType ?? "xterm-256color"; environment["COLORTERM"] = "truecolor"
            if profile.kind == .ssh { environment = SSHEnvironment.remoteClient(environment) }
            else { environment["LC_CTYPE"] = "UTF-8" }
            if profile.kind == .ssh && !reusesSSHConnection {
                let password = oneTimePassword; oneTimePassword = nil
                let broker = try AuthBroker(profile: credentialsForConnection?() ?? profile, oneTimePassword: password, permitsSaving: sshConnectionGroup?.isExternal != true); authBroker = broker
                broker.onSavePassword = onSaveAuthenticatedPassword
                broker.onAuthenticated = { [weak self] in
                    self?.sshConnectionGroup?.authenticatedConnectionReady()
                    self?.sessionReady = true; self?.observeTransportPeer(); self?.refreshHeader(); self?.onState?()
                    self?.schedulePromptScan()
                }
                environment.merge(broker.environment) { _, new in new }
            }
            // Running the bundled transfer helpers from the local test terminal is convenient.
            environment["PATH"] = ZmodemTransfer.helperDirectory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            terminal.startProcess(executable: executable, args: args, environment: environment.map { "\($0.key)=\($0.value)" },
                                  currentDirectory: NSHomeDirectory())
            if reusesSSHConnection { sessionReady = true }
            refreshHeader(); onState?()
        } catch { ended = true; refreshHeader(); beginEndedInput(); onState?(); onError?(error.localizedDescription) }
    }
    private func beginEndedInput() {
        guard endedInput == nil else { return }
        endedInput = EndedSessionInput(allowsLocalTools: true)
        // Clear style and show a cursor even if the remote application hid it.
        terminal.feed(byteArray: Array("\u{1b}[0m\u{1b}[?25h\r\n本机网络工具：help 查看分类，tools 查看安装状态和路径。\r\n输入 exit 或 quit 并回车关闭标签页；⇧⌘R 重连原会话。\r\n\(EndedSessionInput.prompt)".utf8)[...])
    }
    func handleEndedInput(_ bytes: ArraySlice<UInt8>, queueIfExited: Bool = true) {
        guard ended, !isShutdown else { return }
        if let localTool {
            if bytes.contains(3) { pendingLocalInput = [] }
            if localTool.exited { if queueIfExited && pendingLocalInput.count + bytes.count <= 1_048_576 { pendingLocalInput.append(contentsOf: bytes) } }
            else { if queueIfExited { noteUserInput(bytes) }; localTool.send(bytes) }
            return
        }
        beginEndedInput()
        guard var input = endedInput else { return }
        let result = input.consume(bytes)
        endedInput = input
        terminal.feed(byteArray: result.echo[...])
        if result.close { pendingLocalInput = []; onCloseRequested?(self) }
        else if let command = result.command {
            pendingLocalInput = result.remaining; startLocalTool(command)
        }
    }
    func resizeLocalTool() { localTool?.resize(terminal.getWindowSize()) }
    private func startLocalTool(_ command: LocalToolCommand) {
        let task = LocalToolProcess(command: command, size: terminal.getWindowSize())
        localTool = task
        if interactiveTool != nil { resetHostIdentity() } else { useLocalHostIdentity() }
        task.onData = { [weak self, weak task] bytes in
            guard let self, let task, self.localTool === task, !self.isShutdown else { return }
            // Local command output is terminal text, never an SSH ZMODEM stream.
            self.receivedBytes += UInt64(bytes.count); self.display(self.identityOutput(bytes))
        }
        task.onExit = { [weak self, weak task] code in
            guard let self, let task, self.localTool === task, !self.isShutdown else { return }
            self.localTool = nil
            let pendingEcho = self.hostProbeEcho?.flush() ?? Data(); self.hostProbeEcho = nil; self.display(pendingEcho)
            self.useLocalHostIdentity()
            let leaveAlternate = self.terminal.getTerminal().isCurrentBufferAlternate ? "\u{1b}[?1049l" : ""
            self.display(Data(("\u{18}" + leaveAlternate + "\u{1b}[?2004l\u{1b}[0m\u{1b}[?25h\r\n[本机 \(command.name) 已结束，退出码 \(code.map(String.init) ?? "未知")]\r\n\(EndedSessionInput.prompt)").utf8))
            self.refreshHeader(); self.onState?(); self.consumePendingLocalInput()
        }
        do { try task.start(); refreshHeader(); onState?() }
        catch {
            task.stop(); localTool = nil; useLocalHostIdentity()
            display(Data((error.localizedDescription + "\r\n" + EndedSessionInput.prompt).utf8))
            refreshHeader(); onState?(); consumePendingLocalInput()
        }
    }
    private func consumePendingLocalInput() {
        guard !pendingLocalInput.isEmpty, !isShutdown, localTool == nil else { return }
        let pending = pendingLocalInput; pendingLocalInput = []
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShutdown else { return }
            if self.localTool != nil {
                if self.pendingLocalInput.count + pending.count <= 1_048_576 { self.pendingLocalInput.insert(contentsOf: pending, at: 0) }
                else { self.pendingLocalInput = []; self.display(Data("\r\n后续本机输入超过 1 MiB，已取消剩余队列。\r\n".utf8)) }
            }
            else { self.handleEndedInput(pending[...]) }
        }
    }
    func receive(_ incoming: Data) {
        guard !ignoreOutput, !isShutdown else { return }
        let wasRetired = retiredPrimaryOutput; retiredPrimaryOutput = ended
        defer { retiredPrimaryOutput = wasRetired }
        noteActivity()
        var bytes = incoming
        receivedBytes += UInt64(bytes.count)
        bytes = identityOutput(bytes)
        if var drain = abortDrain {
            bytes = drain.consume(bytes)
            abortDrain = drain.finished ? nil : drain
            if bytes.isEmpty { return }
        }
        if let transfer {
            if transfer.receive(bytes) { return }
            remoteReady = true
        }
        if selectionPending {
            selectionBytes.append(bytes)
            if selectionBytes.count > 64 * 1024 { cancelTransfer() }
            return
        }
        guard preferences.autoZmodem else { display(bytes); return }
        let result = detector.consume(bytes)
        display(result.text)
        if finishingTransfer, !result.text.isEmpty { completeFinishing() }
        if let direction = result.direction {
            if finishingTransfer || transfer != nil {
                return
            } else if DispatchTime.now().uptimeNanoseconds < cancellationDeadline {
                sendAbortSequence()
            } else { chooseTransfer(direction, initial: result.protocolBytes) }
        }
    }
    private func display(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        terminal.feed(byteArray: Array(bytes)[...]); logger?.append(bytes)
        searchPanel.bufferDidChange()
        schedulePromptScan()
        if outputActivity.consume(bytes), !hasUnreadOutput { onOutput?(self) }
    }
    private func chooseTransfer(_ direction: TransferDirection, initial: Data) {
        if let selection = transferSelection?(direction) {
            beginTransfer(direction, files: selection.files, directory: selection.directory, initialData: initial)
            return
        }
        guard let window = view.window else {
            // A background tab is activated by the controller before presenting a chooser.
            onFocus?(self)
            DispatchQueue.main.async { [weak self] in self?.chooseTransfer(direction, initial: initial) }
            return
        }
        selectionPending = true; selectionBytes = initial; transferToken = UUID()
        let token = transferToken
        transferProgress.begin(direction == .upload ? "选择要上传的文件…" : "选择下载保存文件夹…"); onState?()
        let panel = NSOpenPanel(); chooser = panel
        panel.title = direction == .upload ? "ZMODEM 上传" : "ZMODEM 下载"
        panel.prompt = direction == .upload ? "上传" : "保存到这里"
        panel.canChooseFiles = direction == .upload; panel.canChooseDirectories = direction == .download
        panel.allowsMultipleSelection = direction == .upload; panel.canCreateDirectories = direction == .download
        panel.message = direction == .upload ? "上传到远端 rz 当前所在的目录。" : "同名文件自动增加编号，不覆盖已有文件。"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.transferToken == token, self.selectionPending else { return }
            self.chooser = nil
            guard response == .OK, !panel.urls.isEmpty else { self.cancelTransfer(); return }
            let initialBytes = self.selectionBytes
            self.selectionBytes = Data(); self.selectionPending = false
            self.beginTransfer(direction, files: direction == .upload ? panel.urls : [], directory: direction == .download ? panel.url : nil, initialData: initialBytes)
        }
    }
    private func beginTransfer(_ direction: TransferDirection, files: [URL], directory: URL?, initialData: Data) {
        remoteReady = false; finishingTransfer = false; abortDrain = nil
        transferProgress.begin(direction == .upload ? "正在准备上传…" : "正在准备下载…")
        let transfer = ZmodemTransfer(direction: direction, expectedHostname: remoteHostname); self.transfer = transfer
        transfer.onBytes = { [weak self] bytes in self?.terminal.process.send(data: Array(bytes)[...]) }
        transfer.onProgress = { [weak self] value in self?.transferProgress.update(value, direction: direction) }
        transfer.onEnd = { [weak self] code in self?.finishTransfer(code: code) }
        transfer.onTerminalBytes = { [weak self] bytes in self?.remoteReady = true; self?.display(bytes) }
        onState?()
        do { try transfer.start(files: files, directory: directory, initialData: initialData) }
        catch { cancelTransfer(); onError?("无法开始 ZMODEM 传输：\(error.localizedDescription)") }
    }
    private func finishTransfer(code: Int32) {
        transfer = nil; selectionPending = false; selectionBytes = Data(); detector = ZmodemDetector()
        finishMessage = code == 0 ? "传输完成" : "传输已中断或失败（\(code)）"
        finishingTransfer = true; transferProgress.status("正在恢复终端…", completed: code == 0)
        if code != 0 { sendAbortSequence() }
        // Never synthesize Return on success: it could execute a stale protocol frame in Bash.
        if remoteReady { completeFinishing() } else { finishDeadline() }
        onState?()
    }
    private func completeFinishing() {
        guard finishingTransfer else { return }
        finishingTransfer = false; cancellationDeadline = 0; transferToken = UUID()
        transferProgress.status(finishMessage)
        let token = transferToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.transferToken == token, !self.isTransferring else { return }
            self.transferProgress.hide()
        }
        onState?()
    }
    private func finishDeadline() {
        transferToken = UUID(); let token = transferToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.transferToken == token, self.finishingTransfer else { return }
            if self.abortDrain != nil {
                self.ignoreOutput = true; self.ended = true; self.finishingTransfer = false
                self.terminal.terminate(); self.stopLogging(); self.refreshHeader()
                self.beginEndedInput()
                self.transferProgress.status("取消无响应，连接已关闭，请重新连接。"); self.onState?(); return
            }
            self.completeFinishing()
        }
    }
    @objc private func cancelAction() { cancelTransfer() }
    func cancelTransfer() {
        if !ended, finishingTransfer, transfer == nil, !selectionPending { return }
        transferToken = UUID(); chooser?.cancel(nil); chooser = nil
        let wasActive = isTransferring
        transfer?.onEnd = nil; transfer?.onBytes = nil; transfer?.onProgress = nil; transfer?.onTerminalBytes = nil; transfer?.cancel(); transfer = nil
        selectionPending = false; selectionBytes = Data(); detector = ZmodemDetector()
        remoteReady = false
        if wasActive, terminal.process.running, !ended {
            abortDrain = AbortDrain()
            finishingTransfer = true; finishMessage = "传输已取消，部分文件可能保留。"
            transferProgress.status("正在取消传输…")
            cancellationDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
            sendAbortSequence()
            finishDeadline(); let token = transferToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.transferToken == token, self.finishingTransfer, self.terminal.process.running,
                      self.transfer == nil, !self.selectionPending else { return }
                self.terminal.process.send(data: [3, 13][...])
            }
        } else {
            finishingTransfer = false; transferProgress.hide()
        }
        onState?()
    }
    private func sendAbortSequence() {
        // lrzsz's canonical abort sequence: ten CAN bytes followed by ten backspaces.
        let bytes = Array(repeating: UInt8(24), count: 10) + Array(repeating: UInt8(8), count: 10)
        terminal.process.send(data: bytes[...])
    }
    func startLogging(to url: URL) throws {
        logger?.stop()
        logger = try SessionLogger(url: url)
        logger?.onError = { [weak self] message in self?.logger = nil; self?.refreshHeader(); self?.onState?(); self?.onError?(message) }
        refreshHeader(); onState?()
    }
    func stopLogging() { logger?.stop(); logger = nil; refreshHeader(); onState?() }
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        searchPanel.dispose()
        if let window = terminal.window, let responder = window.firstResponder as? NSView,
           responder === terminal || responder.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
        onCloseRequested = nil; endedInput = nil; onOutput = nil; hasUnreadOutput = false
        promptScan?.cancel(); promptScan = nil
        hostProbeWork?.cancel(); hostProbeWork = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil
        hostProbeToken = nil; hostProbeEcho = nil
        oneTimePassword = nil
        localTool?.stop(); localTool = nil; pendingLocalInput = []
        idleTimer?.cancel(); idleTimer = nil; sessionReady = false
        ended = true; onState = nil; cancelTransfer(); stopLogging()
        authBroker?.stop(); authBroker = nil
        terminal.processDelegate = nil; terminal.terminate(); terminal.owner = nil
        sshConnectionGroup?.detach(id); sshConnectionGroup = nil
        // Release rendering resources immediately, even if AppKit temporarily
        // keeps a closed view alive through its responder/animation machinery.
        terminal.foregroundHighlightProvider = nil
        try? terminal.setUseMetal(false)
        onFocus = nil; onUserInput = nil; onPaste = nil; onFilesDropped = nil; onError = nil; transferSelection = nil
    }
    private func refreshHeader() {
        header.stringValue = title + (isRunningLocalTool ? " · 本机工具：" + (localToolName ?? "") : (ended ? " · 本机工具模式" : "")) + (isLogging ? " · 记录中" : "")
        header.toolTip = connectionDetails
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) { searchPanel.bufferDidChange(resized: true) }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard observesHostIdentity else { return }
        if let token = hostProbeToken, title.hasPrefix(token) {
            guard hostProbeEpoch == hostEpoch else { return }
            hostProbeToken = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil
            if !hasShellIntegration, let identity = RemoteHostIdentity.parse(String(title.dropFirst(token.count))) { applyHostIdentity(identity) }
        } else if let host = TerminalHostname.fromTitle(title) {
            if integratedPromptPending {
                hostAliases.insert(host); integratedPromptPending = false
            } else { updateHostname(host) }
        }
    }
    private func applyHostIdentity(_ identity: RemoteHostIdentity) {
        let hostname = displayHostname(identity.hostname)
        if profile.kind == .ssh, !ended, canBindInitialHost { initialRemoteHostname = identity.hostname }
        hostAliases = Set([currentHostHint, identity.hostname, hostname].compactMap { $0 })
        remoteHostname = hostname; remoteAddress = identity.address; attemptedHostEpoch = hostEpoch
        noteActivity(); startIdleTimer()
        applyHighlights(highlightSet); refreshHeader(); onState?()
    }
    private func matchesCurrentHost(_ host: String) -> Bool {
        hostAliases.contains { RemoteHostIdentity.sameHost($0, host) }
    }
    private func displayHostname(_ hint: String) -> String {
        guard profile.kind == .local || (ended && interactiveTool == nil) else { return hint }
        let names = LocalHostIdentity.hostnameSnapshot()
        // Shell variables may retain an earlier runtime name after VPN changes.
        knownLocalHostnames.formUnion(names.aliases)
        let key = hint.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return knownLocalHostnames.contains(key) ? names.hostname : hint
    }
    private func updateHostname(_ hint: String) {
        guard observesHostIdentity else { return }
        guard !integratedPromptPending else { return }
        let host = displayHostname(hint)
        lastPromptText = terminal.getTerminal().getCursorLineText()
        currentHostHint = host
        guard !matchesCurrentHost(host) else { return }
        hostEpoch += 1; hostAliases = [host]; remoteHostname = host; remoteAddress = nil
        if profile.kind == .ssh, !ended, canBindInitialHost, initialRemoteHostname == nil { initialRemoteHostname = host }
        hostProbeWork?.cancel(); hostProbeWork = nil
        hostProbeTimeout?.cancel(); hostProbeTimeout = nil; hostProbeToken = nil
        applyHighlights(highlightSet); refreshHeader(); onState?()
    }
    func noteUserInput(_ bytes: ArraySlice<UInt8>) {
        hostProbeWork?.cancel(); hostProbeWork = nil
        if observesHostIdentity, bytes.contains(4) || bytes.contains(13) || bytes.contains(10) {
            let currentLine = terminal.getTerminal().getCursorLineText()
            if bytes.contains(4) || RemoteHostIdentity.changesHost(currentLine, containsPrompt: true)
                || RemoteHostIdentity.changesHost(String(decoding: bytes, as: UTF8.self), containsPrompt: false) {
                canBindInitialHost = false
                hostEpoch += 1; attemptedHostEpoch = nil; remoteAddress = nil
                if !allowsActiveHostProbe { remoteHostname = nil; currentHostHint = nil; hostAliases = []; lastPromptText = "" }
                integratedPromptPending = false
                hostProbeToken = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil
                let remainder = hostProbeEcho?.flush() ?? Data(); hostProbeEcho = nil
                display(remainder); refreshHeader(); onState?()
            }
        }
        for byte in bytes {
            if [3, 4, 10, 13, 21].contains(byte) { userEditingLine = false }
            else { userEditingLine = true }
        }
    }
    private func schedulePromptScan() {
        guard observesHostIdentity, promptScan == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.promptScan = nil
            let model = self.terminal.getTerminal()
            guard self.observesHostIdentity, !model.isCurrentBufferAlternate else { return }
            let text = model.getCursorLineText()
            guard let host = TerminalHostname.fromPrompt(text) else { return }
            self.startIdleTimer()
            if self.integratedPromptPending {
                // Bind the actual prompt alias to the just-reported identity.
                self.integratedPromptPending = false; self.hostAliases.insert(host); self.lastPromptText = text
            } else if text != self.lastPromptText { self.lastPromptText = text; self.updateHostname(host) }
            guard self.allowsActiveHostProbe, self.matchesCurrentHost(host), !self.userEditingLine, self.hostProbeToken == nil,
                  self.attemptedHostEpoch != self.hostEpoch, self.hostProbeWork == nil,
                  self.identityShellReady, !self.isTransferring else { return }
            let epoch = self.hostEpoch
            let probe = DispatchWorkItem { [weak self] in
                guard let self else { return }; self.hostProbeWork = nil
                guard self.hostEpoch == epoch, !self.userEditingLine,
                      self.terminal.getTerminal().getCursorLineText() == text else { return }
                self.refreshHostIdentity()
            }
            self.hostProbeWork = probe; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: probe)
        }
        promptScan = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    var canRefreshHostIdentity: Bool {
        if !isShutdown && ended && interactiveTool == nil { return true }
        return observesHostIdentity && identityShellReady
            && !isTransferring && !userEditingLine && !terminal.getTerminal().isCurrentBufferAlternate && hostProbeToken == nil
            && !RemoteHostIdentity.isAuthenticationPrompt(terminal.getTerminal().getCursorLineText())
    }
    func refreshHostIdentity() {
        guard canRefreshHostIdentity else { return }
        if ended && interactiveTool == nil { useLocalHostIdentity(); return }
        if !allowsActiveHostProbe { schedulePromptScan(); return }
        hostProbeWork?.cancel(); hostProbeWork = nil
        let token = "OSHELL_INFO_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + ":"
        let command = RemoteHostIdentity.command(token: token)
        hostProbeToken = token; hostProbeEpoch = hostEpoch; attemptedHostEpoch = hostEpoch
        remoteAddress = nil; refreshHeader(); onState?()
        hostProbeEcho = HostProbeEcho(command: command)
        let bytes = Array((command + "\r").utf8)
        if let tool = interactiveTool { tool.send(bytes[...]) } else { terminal.process.send(data: bytes[...]) }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.hostProbeToken == token else { return }
            self.hostProbeToken = nil; self.hostProbeTimeout = nil
            let remainder = self.hostProbeEcho?.flush() ?? Data(); self.hostProbeEcho = nil
            if !self.isShutdown { self.display(remainder) }
        }
        hostProbeTimeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }
    private func receiveShellIdentity(_ bytes: ArraySlice<UInt8>) {
        guard profile.titleMode != .passive, observesHostIdentity, !terminal.getTerminal().isCurrentBufferAlternate,
              let identity = RemoteHostIdentity.integrationReport(bytes) else { return }
        hasShellIntegration = true; integratedPromptPending = true
        currentHostHint = nil
        hostProbeWork?.cancel(); hostProbeWork = nil
        applyHostIdentity(identity)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard observesHostIdentity else { return }
        if let directory, let host = TerminalHostname.fromDirectory(directory) { updateHostname(host) }
        if !ended, profile.kind == .ssh, let directory, let url = URL(string: directory), url.scheme == "file", let host = url.host,
           [profile.host, initialRemoteHostname ?? ""].contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }), !url.path.isEmpty,
           (try? RemotePath.validate(url.path)) != nil { remoteDirectory = url.path }
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        idleTimer?.cancel(); idleTimer = nil; sessionReady = false
        hostProbeWork?.cancel(); hostProbeWork = nil; hostProbeTimeout?.cancel(); hostProbeTimeout = nil; hostProbeToken = nil
        let pendingEcho = hostProbeEcho?.flush() ?? Data(); hostProbeEcho = nil; display(pendingEcho)
        authBroker?.stop(); authBroker = nil
        ended = true; cancelTransfer(); display(detector.flush()); stopLogging(); refreshHeader()
        display(Data("\r\n[OShell · 连接已结束，标签仍保留，退出码 \(exitCode.map(String.init) ?? "未知")]\r\n".utf8))
        if reusesSSHConnection, exitCode != 0 {
            display(Data("[复用终端未能保持连接；若服务器拒绝多通道或共享连接失效，请重新建立会话。不会回退到密码重试。]\r\n".utf8))
        }
        useLocalHostIdentity(); beginEndedInput()
        onState?()
    }
    deinit { idleTimer?.cancel(); localTool?.stop(); terminal.terminate(); sshConnectionGroup?.detach(id); logger?.stop() }
}

indirect enum PaneLayout {
    case pane(TerminalPane)
    case split(NSSplitView, PaneLayout, PaneLayout)
    var view: NSView { switch self { case .pane(let pane): return pane.view; case .split(let split, _, _): return split } }
    var minimumSize: NSSize {
        switch self {
        case .pane: return NSSize(width: 220, height: 140)
        case .split(let split, let first, let second):
            let a = first.minimumSize, b = second.minimumSize
            return NSSize(width: split.isVertical ? a.width + b.width + split.dividerThickness : max(a.width, b.width),
                          height: split.isVertical ? max(a.height, b.height) : a.height + b.height + split.dividerThickness)
        }
    }
    var panes: [TerminalPane] { switch self { case .pane(let pane): return [pane]; case .split(_, let first, let second): return first.panes + second.panes } }
    func replacing(_ id: UUID, with replacement: PaneLayout) -> PaneLayout {
        switch self {
        case .pane(let pane): return pane.id == id ? replacement : self
        case .split(let splitter, let first, let second):
            let a = first.replacing(id, with: replacement), b = second.replacing(id, with: replacement)
            if first.view !== a.view { if first.view.superview === splitter { first.view.removeFromSuperview() }; splitter.insertArrangedSubview(a.view, at: 0) }
            if second.view !== b.view { if second.view.superview === splitter { second.view.removeFromSuperview() }; splitter.addArrangedSubview(b.view) }
            splitter.adjustSubviews(); return .split(splitter, a, b)
        }
    }
    func removing(_ id: UUID) -> PaneLayout? {
        switch self {
        case .pane(let pane): return pane.id == id ? nil : self
        case .split(let splitter, let first, let second):
            guard let a = first.removing(id) else { second.view.removeFromSuperview(); return second }
            guard let b = second.removing(id) else { first.view.removeFromSuperview(); return first }
            if first.view !== a.view { first.view.removeFromSuperview(); splitter.insertArrangedSubview(a.view, at: 0) }
            if second.view !== b.view { second.view.removeFromSuperview(); splitter.addArrangedSubview(b.view) }
            splitter.adjustSubviews(); return .split(splitter, a, b)
        }
    }
}
final class TerminalTab {
    let id = UUID()
    var layout: PaneLayout
    var activePane: TerminalPane
    var hasUnreadOutput: Bool { layout.panes.contains(where: \.hasUnreadOutput) }
    func markOutputRead() { layout.panes.forEach { $0.markOutputRead() } }
    init(_ pane: TerminalPane) { layout = .pane(pane); activePane = pane }
}
