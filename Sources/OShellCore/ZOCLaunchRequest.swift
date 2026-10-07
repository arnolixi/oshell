// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation

/// The connection-only subset used by USM's macOS ZOC launcher. Never persist this type.
public struct ZOCLaunchRequest: Codable {
    public var version = 1
    public var id = UUID()
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var keyFile: String
    public var title: String
    public var terminalType: String

    public func profile() throws -> SessionProfile {
        guard version == 1, ["xterm", "vt100", "linux"].contains(terminalType),
              host.utf8.count <= 253, title.utf8.count <= 2048, username.utf8.count <= 1024, keyFile.utf8.count <= 4096,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !keyFile.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ModelError.invalid("ZOC 连接参数无效或过长。") }
        if let password {
            guard password.utf8.count <= 4096, !password.contains("\0"), !password.contains("\r"), !password.contains("\n"), !username.isEmpty else { throw ModelError.invalid("ZOC 登录凭据格式无效。") }
        }
        var result = SessionProfile(name: "SSH · " + host, group: "", host: host, port: port, username: username, identityFile: keyFile)
        result.quickConnect = false
        try result.validate(); return result
    }
    public static func parse(_ arguments: [String]) throws -> ZOCLaunchRequest {
        guard arguments.count <= 32, arguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else { throw ModelError.invalid("ZOC 启动参数过长。") }
        var values = [String: String](), index = 0
        let supported: Set<String> = ["DEV", "CONNECT", "SSH", "SSHUSER", "SSHPASSWORD", "SSHKEY", "TITLE", "EMU", "CHARSET", "ENCODING"]
        while index < arguments.count {
            let argument = arguments[index]; index += 1
            guard argument.first == "/" || argument.first == "-" else { throw ModelError.invalid("ZOC 参数格式无效；请使用 /参数:值 或 -参数 值。") }
            let body = String(argument.drop(while: { $0 == "/" || $0 == "-" }))
            let separator = body.firstIndex(where: { $0 == ":" || $0 == "=" })
            let name = String(separator.map { body[..<$0] } ?? body[...]).uppercased()
            guard supported.contains(name), values[name] == nil else { throw ModelError.invalid("含有不支持或重复的 ZOC 参数；此入口只处理连接，不执行脚本或配置文件。") }
            let value: String
            if let separator { value = String(body[body.index(after: separator)...]) }
            else { guard index < arguments.count else { throw ModelError.invalid("ZOC 参数缺少值。") }; value = arguments[index]; index += 1 }
            values[name] = value
        }
        guard (values["CONNECT"] == nil) != (values["SSH"] == nil) else { throw ModelError.invalid("需要且只能指定一个 /CONNECT 或 /SSH 目标。") }
        var destination = values["CONNECT"] ?? values["SSH"]!, device = values["DEV"]?.uppercased() ?? "SSH"
        if let bang = destination.firstIndex(of: "!"), ["SSH", "SSH2", "SECURE SHELL", "SSH (SECURE SHELL)", "TELNET", "RLOGIN"].contains(String(destination[..<bang]).uppercased()) {
            let embedded = String(destination[..<bang]).uppercased()
            guard values["DEV"] == nil || device == embedded else { throw ModelError.invalid("ZOC 连接类型冲突。") }
            device = embedded; destination = String(destination[destination.index(after: bang)...])
        }
        guard ["SSH", "SSH2", "SECURE SHELL", "SSH (SECURE SHELL)"].contains(device) else {
            throw ModelError.invalid("当前兼容入口支持 SSH 传输。此版 USM 的 SSH/Telnet/Rlogin 分组均通过 /DEV:SSH 调用；不支持原生 Telnet/Rlogin 启动参数。")
        }
        let encoding = values["CHARSET"] ?? values["ENCODING"] ?? "UTF-8"
        guard ["UTF-8", "UTF8"].contains(encoding.uppercased()) else { throw ModelError.invalid("当前启动入口只支持 UTF-8 编码。") }
        var username = "", password: String?
        if let at = destination.lastIndex(of: "@") {
            let credentials = String(destination[..<at]); destination = String(destination[destination.index(after: at)...])
            if let colon = credentials.firstIndex(of: ":") {
                username = String(credentials[..<colon]); password = String(credentials[credentials.index(after: colon)...])
            } else { username = credentials }
        }
        if let value = values["SSHUSER"] { username = value }
        if let value = values["SSHPASSWORD"] { password = value }
        var host = destination, port = 22
        if destination.hasPrefix("[") {
            guard let close = destination.firstIndex(of: "]") else { throw ModelError.invalid("ZOC IPv6 地址格式无效。") }
            host = String(destination[destination.index(after: destination.startIndex)..<close])
            let suffix = String(destination[destination.index(after: close)...])
            if !suffix.isEmpty {
                guard suffix.first == ":", let number = Int(suffix.dropFirst()) else { throw ModelError.invalid("ZOC 端口无效。") }; port = number
            }
        } else if destination.filter({ $0 == ":" }).count == 1, let colon = destination.lastIndex(of: ":") {
            host = String(destination[..<colon])
            guard let number = Int(destination[destination.index(after: colon)...]) else { throw ModelError.invalid("ZOC 端口无效。") }; port = number
        }
        let request = ZOCLaunchRequest(host: host, port: port, username: username, password: password,
                                       keyFile: values["SSHKEY"] ?? "", title: values["TITLE"] ?? "", terminalType: (values["EMU"] ?? "Xterm").lowercased())
        _ = try request.profile(); return request
    }
}

public struct ZOCLaunchResponse: Codable {
    public var accepted: Bool
    public var message: String
    public init(accepted: Bool, message: String = "") { self.accepted = accepted; self.message = message }
}
