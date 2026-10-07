// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin
import OShellCore

signal(SIGPIPE, SIG_IGN)
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] || arguments == ["-v"] { print("OShell FileZilla-compatible launcher (compatibility level 3.70.0)"); exit(0) }
if arguments == ["--help"] || arguments == ["-h"] {
    print("OShell FileZilla-compatible launcher: --site=0/folder/site or ftp:// / sftp:// URL. Opens OShell file tabs; does not run FileZilla."); exit(0)
}
do {
    let request: FileLaunchRequest
    do {
        defer { for i in 1..<Int(CommandLine.argc) { if let value = CommandLine.unsafeArgv[i] { memset(value, 0, strlen(value)) } } }
        request = try FileLaunchRequest.parse(arguments)
    }
    try ExternalLaunchClient.send(ExternalLaunchRequest(file: request)); exit(0)
} catch {
    let message = (error as? ModelError)?.localizedDescription ?? "OShell 文件启动失败，请检查站点配置和应用版本。"
    FileHandle.standardError.write(Data((message + "\n").utf8))
    if ProcessInfo.processInfo.environment["OSHELL_LAUNCH_NO_UI"] != "1" {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "OShell 文件启动失败"; alert.informativeText = message
        alert.addButton(withTitle: "关闭").keyEquivalent = "\u{1b}"; alert.runModal()
    }
    exit(1)
}
