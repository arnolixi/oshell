// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

public enum SessionKind: String, Codable, CaseIterable {
    case ssh, sftp, ftp, local
    public var title: String { self == .local ? "本地" : rawValue.uppercased() }
    public var usesSSH: Bool { self == .ssh || self == .sftp }
    public var isFileSession: Bool { self == .sftp || self == .ftp }
}
public struct SessionProfile: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var group: String
    public var kind: SessionKind
    public var host: String
    public var port: Int
    public var username: String
    public var identityFile: String
    public var jumpHost: String
    public var encryptedPassword: EncryptedPassword?
    public var tunnels: [TunnelRule] = []
    public var proxy = ProxySettings()
    public var keepAlive = KeepAliveSettings()
    public var legacySSH = false
    public var titleMode: HostTitleMode = .shellIntegration
    /// Compatibility for callers using the former opt-in switch.
    public var activeHostProbe: Bool {
        get { titleMode == .activeProbe }
        set { titleMode = newValue ? .activeProbe : .shellIntegration }
    }
    public var quickConnect = true
    public var initialDirectory = "."
    public init(id: UUID = UUID(), name: String = "新会话", group: String = "服务器", kind: SessionKind = .ssh,
                host: String = "", port: Int = 22, username: String = "", identityFile: String = "", jumpHost: String = "") {
        self.id = id; self.name = name; self.group = group; self.kind = kind; self.host = host
        self.port = port; self.username = username; self.identityFile = identityFile; self.jumpHost = jumpHost
        self.encryptedPassword = nil
    }
    private enum CodingKeys: String, CodingKey { case id, name, group, kind, host, port, username, identityFile, jumpHost, encryptedPassword, tunnels, proxy, keepAlive, legacySSH, titleMode, quickConnect, initialDirectory }
    private enum LegacyCodingKeys: String, CodingKey { case activeHostProbe }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try fields.decode(UUID.self, forKey: .id), name: try fields.decode(String.self, forKey: .name),
                  group: try fields.decode(String.self, forKey: .group), kind: try fields.decode(SessionKind.self, forKey: .kind),
                  host: try fields.decode(String.self, forKey: .host), port: try fields.decode(Int.self, forKey: .port),
                  username: try fields.decode(String.self, forKey: .username), identityFile: try fields.decode(String.self, forKey: .identityFile),
                  jumpHost: try fields.decode(String.self, forKey: .jumpHost))
        encryptedPassword = try fields.decodeIfPresent(EncryptedPassword.self, forKey: .encryptedPassword)
        tunnels = try fields.decodeIfPresent([TunnelRule].self, forKey: .tunnels) ?? []
        proxy = try fields.decodeIfPresent(ProxySettings.self, forKey: .proxy) ?? ProxySettings()
        keepAlive = try fields.decodeIfPresent(KeepAliveSettings.self, forKey: .keepAlive) ?? KeepAliveSettings()
        legacySSH = try fields.decodeIfPresent(Bool.self, forKey: .legacySSH) ?? false
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        titleMode = try fields.decodeIfPresent(HostTitleMode.self, forKey: .titleMode)
            ?? ((try legacy.decodeIfPresent(Bool.self, forKey: .activeHostProbe) ?? false) ? .activeProbe : .shellIntegration)
        quickConnect = try fields.decodeIfPresent(Bool.self, forKey: .quickConnect) ?? true
        initialDirectory = try fields.decodeIfPresent(String.self, forKey: .initialDirectory) ?? (kind == .ftp ? "/" : ".")
    }
    public static var local: SessionProfile { .init(name: "本地终端", group: "本机", kind: .local) }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.invalid("请填写会话名称。") }
        if kind == .local { return }
        try RemotePath.validate(initialDirectory)
        guard !initialDirectory.isEmpty else { throw ModelError.invalid("请填写文件初始目录，主目录可填写 .。"); }
        if kind == .ftp { try ftpProfile.validate(); return }
        guard (1...65535).contains(port) else { throw ModelError.invalid("端口应在 1–65535 之间。") }
        guard ConnectionValidation.host(host) else {
            throw ModelError.invalid("请填写主机地址或 SSH 配置中的主机别名。")
        }
        guard username.isEmpty || (!username.hasPrefix("-") && Self.isToken(username)) else { throw ModelError.invalid("用户名不能包含空白或控制字符。") }
        guard jumpHost.isEmpty || (!jumpHost.hasPrefix("-") && jumpHost.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:,[]").contains($0) }) else { throw ModelError.invalid("跳板机格式无效。") }
        try proxy.validate(); try keepAlive.validate()
        for tunnel in tunnels where tunnel.enabled { try tunnel.validate() }
        let listeners = tunnels.filter(\.enabled).map { "\($0.kind == .remote ? "remote" : "local"):\($0.bindHost):\($0.listenPort)" }
        guard Set(listeners).count == listeners.count else { throw ModelError.invalid("隧道监听地址和端口重复。") }
        guard jumpHost.isEmpty || proxy.kind == .none else { throw ModelError.invalid("旧跳板机字段与代理不能同时设置，请将跳板机迁移到代理页。") }
        guard !identityFile.contains("\0") else { throw ModelError.invalid("私钥路径无效。") }
    }
    private static func isToken(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
    public func sshArguments(knownHostsFile: URL? = nil, proxyHelper: URL? = nil) throws -> [String] {
        guard kind.usesSSH else { throw ModelError.invalid("此会话不是 SSH / SFTP 协议。"); }
        try validate()
        var args = ["-tt", "-p", String(port), "-o", "ServerAliveInterval=\(keepAlive.enabled ? keepAlive.interval : 0)", "-o", "ServerAliveCountMax=\(keepAlive.maxMissed)", "-o", "TCPKeepAlive=\(keepAlive.tcp ? "yes" : "no")",
                    "-o", "StrictHostKeyChecking=ask", "-o", "ConnectTimeout=15"]
        if !username.isEmpty { args += ["-l", username] }
        if !identityFile.isEmpty { args += ["-i", NSString(string: identityFile).expandingTildeInPath] }
        if !jumpHost.isEmpty { args += ["-J", jumpHost] }
        if proxy.kind == .jump {
            args += ["-J", (proxy.username.isEmpty ? "" : proxy.username + "@") + ConnectionValidation.bracket(proxy.host) + ":\(proxy.port)"]
        } else if proxy.needsHelper {
            let helper = proxyHelper ?? URL(fileURLWithPath: "/usr/bin/true") // ssh -G resolves identity without launching a proxy.
            args += ["-o", "ProxyCommand=" + proxy.command(helper: helper, tcpKeepAlive: keepAlive.tcp)]
        }
        if legacySSH {
            args += ["-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedKeyTypes=+ssh-rsa",
                     "-o", "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1",
                     "-o", "Ciphers=+aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc", "-o", "MACs=+hmac-sha1,hmac-sha1-96"]
        }
        if tunnels.contains(where: \.enabled) { args += ["-o", "ExitOnForwardFailure=yes"] }
        for tunnel in tunnels where tunnel.enabled { args += tunnel.arguments }
        if let knownHostsFile {
            let path = knownHostsFile.path
            guard !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else { throw ModelError.invalid("主机指纹文件路径无效。"); }
            let quoted = path.replacingOccurrences(of: "%", with: "%%").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            args += ["-o", "UserKnownHostsFile=\"\(quoted)\""]
        }
        return args + ["--", host]
    }
}
extension SessionProfile {
    public var ftpProfile: FTPProfile {
        var value = FTPProfile(); value.id = id; value.name = name; value.host = host; value.port = port
        value.username = username; value.encryptedPassword = encryptedPassword; value.initialDirectory = initialDirectory; return value
    }
    public static func fromLegacyFTP(_ ftp: FTPProfile) -> SessionProfile {
        var value = SessionProfile(id: ftp.id, name: ftp.name, group: "FTP", kind: .ftp, host: ftp.host, port: ftp.port, username: ftp.username)
        value.encryptedPassword = ftp.encryptedPassword; value.initialDirectory = ftp.initialDirectory; return value
    }
}
public enum ModelError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
public struct Preferences: Codable {
    public var fontName: String = ""
    public var fontSize: Double = 13
    public var scrollback: Int = 3000
    public var interfaceTheme: InterfaceTheme = .system
    public var colorSchemeID = "oshell-dark"
    public var customColorSchemes: [TerminalColorScheme] = []
    public var colorSchemes: [TerminalColorScheme] { TerminalColorScheme.presets + customColorSchemes }
    public var colorScheme: TerminalColorScheme {
        colorSchemes.first { $0.id == colorSchemeID && (try? $0.validate()) != nil } ?? TerminalColorScheme.presets[0]
    }
    public var darkTheme: Bool {
        get { colorScheme.isDark }
        set { colorSchemeID = newValue ? "oshell-dark" : "oshell-light" }
    }
    public var metal: Bool = true
    public var autoZmodem: Bool = true
    public var copyOnSelect = true
    public var rightClickPaste = true
    public var confirmMultilinePaste = true
    public var updateRepository = ""
    public var automaticUpdateChecks = false
    public var masterWarningAcknowledged = false
    public var quickSendBarVisible = true
    public var quickSendScope: QuickSendScope = .current
    public var keyboardShortcuts = KeyboardShortcuts()
    public var highlightSetID: UUID? = HighlightSet.standardID
    public init() {}
    private enum CodingKeys: String, CodingKey { case keyboardShortcuts, fontName, fontSize, scrollback, darkTheme, metal, autoZmodem, copyOnSelect, rightClickPaste, confirmMultilinePaste, updateRepository, automaticUpdateChecks, masterWarningAcknowledged, quickSendBarVisible, quickSendScope, highlightSetID, interfaceTheme, colorSchemeID, customColorSchemes }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName) ?? ""
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        scrollback = try values.decodeIfPresent(Int.self, forKey: .scrollback) ?? 3000
        darkTheme = try values.decodeIfPresent(Bool.self, forKey: .darkTheme) ?? true
        interfaceTheme = (try values.decodeIfPresent(String.self, forKey: .interfaceTheme)).flatMap(InterfaceTheme.init(rawValue:)) ?? .system
        customColorSchemes = try values.decodeIfPresent([TerminalColorScheme].self, forKey: .customColorSchemes) ?? []
        let requested = try values.decodeIfPresent(String.self, forKey: .colorSchemeID)
        if let requested, colorSchemes.contains(where: { $0.id == requested && (try? $0.validate()) != nil }) { colorSchemeID = requested }
        metal = try values.decodeIfPresent(Bool.self, forKey: .metal) ?? true
        autoZmodem = try values.decodeIfPresent(Bool.self, forKey: .autoZmodem) ?? true
        copyOnSelect = try values.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? true
        rightClickPaste = try values.decodeIfPresent(Bool.self, forKey: .rightClickPaste) ?? true
        confirmMultilinePaste = try values.decodeIfPresent(Bool.self, forKey: .confirmMultilinePaste) ?? true
        updateRepository = try values.decodeIfPresent(String.self, forKey: .updateRepository) ?? ""
        automaticUpdateChecks = try values.decodeIfPresent(Bool.self, forKey: .automaticUpdateChecks) ?? false
        masterWarningAcknowledged = try values.decodeIfPresent(Bool.self, forKey: .masterWarningAcknowledged) ?? false
        quickSendBarVisible = try values.decodeIfPresent(Bool.self, forKey: .quickSendBarVisible) ?? true
        quickSendScope = (try values.decodeIfPresent(Int.self, forKey: .quickSendScope)).flatMap(QuickSendScope.init(rawValue:)) ?? .current
        keyboardShortcuts = try values.decodeIfPresent(KeyboardShortcuts.self, forKey: .keyboardShortcuts) ?? KeyboardShortcuts()
        highlightSetID = values.contains(.highlightSetID) ? try values.decodeIfPresent(UUID.self, forKey: .highlightSetID) : HighlightSet.standardID
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(keyboardShortcuts, forKey: .keyboardShortcuts)
        try values.encode(fontName, forKey: .fontName); try values.encode(fontSize, forKey: .fontSize)
        try values.encode(scrollback, forKey: .scrollback); try values.encode(darkTheme, forKey: .darkTheme)
        try values.encode(metal, forKey: .metal); try values.encode(autoZmodem, forKey: .autoZmodem)
        try values.encode(copyOnSelect, forKey: .copyOnSelect); try values.encode(rightClickPaste, forKey: .rightClickPaste)
        try values.encode(confirmMultilinePaste, forKey: .confirmMultilinePaste)
        try values.encode(updateRepository, forKey: .updateRepository)
        try values.encode(automaticUpdateChecks, forKey: .automaticUpdateChecks)
        try values.encode(masterWarningAcknowledged, forKey: .masterWarningAcknowledged)
        try values.encode(quickSendBarVisible, forKey: .quickSendBarVisible)
        try values.encode(quickSendScope.rawValue, forKey: .quickSendScope)
        try values.encode(highlightSetID, forKey: .highlightSetID)
        try values.encode(interfaceTheme.rawValue, forKey: .interfaceTheme); try values.encode(colorSchemeID, forKey: .colorSchemeID)
        try values.encode(customColorSchemes, forKey: .customColorSchemes)
    }
    public mutating func clamp() {
        var ids = Set(TerminalColorScheme.presets.map(\.id))
        customColorSchemes = Array(customColorSchemes.filter { (try? $0.validate()) != nil && ids.insert($0.id).inserted }.prefix(64))
        if !colorSchemes.contains(where: { $0.id == colorSchemeID }) { colorSchemeID = "oshell-dark" }
        fontSize = fontSize.isFinite ? min(26, max(10, fontSize)) : 13
        scrollback = min(20_000, max(500, scrollback))
    }
}
public struct Configuration: Codable {
    public var masterPasswordVerifier: EncryptedPassword?
    public var hasMasterPassword: Bool { masterPasswordVerifier != nil || ConfigurationCredentials.count(in: self) > 0 }
    public var sessionDefaults = SessionDefaults()
    public var sessionLinks = SessionLinks()
    public var profiles: [SessionProfile]
    public var preferences: Preferences
    public var directories: [String] = []
    public var quickCommands: [QuickCommand] = []
    public var highlightSets: [HighlightSet] = [.standard]
    public var ftpProfiles: [FTPProfile] = []
    public init(profiles: [SessionProfile] = [.local], preferences: Preferences = Preferences()) {
        self.profiles = profiles; self.preferences = preferences
    }
    private enum CodingKeys: String, CodingKey { case profiles, preferences, directories, quickCommands, highlightSets, ftpProfiles, sessionLinks, sessionDefaults, masterPasswordVerifier }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionLinks = try values.decodeIfPresent(SessionLinks.self, forKey: .sessionLinks) ?? SessionLinks()
        sessionDefaults = try values.decodeIfPresent(SessionDefaults.self, forKey: .sessionDefaults) ?? SessionDefaults()
        masterPasswordVerifier = try values.decodeIfPresent(EncryptedPassword.self, forKey: .masterPasswordVerifier)
        profiles = try values.decode([SessionProfile].self, forKey: .profiles)
        preferences = try values.decode(Preferences.self, forKey: .preferences)
        directories = try values.decodeIfPresent([String].self, forKey: .directories) ?? []
        quickCommands = try values.decodeIfPresent([QuickCommand].self, forKey: .quickCommands) ?? []
        highlightSets = try values.decodeIfPresent([HighlightSet].self, forKey: .highlightSets) ?? [.standard]
        ftpProfiles = try values.decodeIfPresent([FTPProfile].self, forKey: .ftpProfiles) ?? []
        for index in profiles.indices { profiles[index].group = SessionDirectory.normalize(profiles[index].group) }
        normalizeSessionLinkDirectories()
    }
    public mutating func migrateFileSessions() throws {
        // Preserve identity-bound encrypted passwords. A collision with different
        // data is an error, never silently overwrite an existing session.
        var migrated = profiles
        for ftp in ftpProfiles {
            let session = SessionProfile.fromLegacyFTP(ftp)
            if let existing = migrated.first(where: { $0.id == ftp.id }) {
                guard existing.kind == .ftp, existing.ftpProfile == ftp else { throw ModelError.invalid("旧 FTP 配置与会话 ID 冲突，已保留原配置。") }
            } else { migrated.append(session) }
        }
        profiles = migrated; ftpProfiles = []; normalizeSessionLinkDirectories()
    }
}
public final class ConfigurationStore {
    public let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("configuration.json") }
    public func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        var config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        try config.migrateFileSessions()
        config.sessionLinks.normalize(profiles: config.profiles)
        config.preferences.clamp()
        try config.sessionDefaults.validate()
        for profile in config.profiles { try profile.validate() }
        for command in config.quickCommands { try command.validate() }
        for profile in config.ftpProfiles { try profile.validate() }
        for set in config.highlightSets {
            guard set.rules.count <= 32 else { throw ModelError.invalid("突出显示集最多允许 32 条规则。"); }
            for rule in set.rules { try rule.validate() }
        }
        return config
    }
    public func save(_ config: Configuration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFile.write(encoder.encode(config), to: url)
    }
}
