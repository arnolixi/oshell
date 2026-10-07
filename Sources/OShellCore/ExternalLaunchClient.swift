// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import AppKit
import Darwin

public enum ExternalLaunchClient {
    public static func applicationExecutable(from source: URL) -> URL {
        var parent = source.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension == "app", Bundle(url: parent)?.bundleIdentifier == "app.oshell.mac" { return parent.appendingPathComponent("Contents/MacOS/OShell") }
            parent.deleteLastPathComponent()
        }
        return source.deletingLastPathComponent().appendingPathComponent("OShell")
    }
    public static func send(_ request: ExternalLaunchRequest) throws {
        try request.validate()
        let directory = try LaunchEndpoint.directory(for: LaunchEndpoint.configurationDirectory)
        let lockFD = try LaunchEndpoint.lock("launch.lock", directory: directory)
        defer { close(lockFD) }
        var client = try? LaunchEndpoint.connect(directory: directory)
        if client == nil {
            if ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] == nil,
               NSRunningApplication.runningApplications(withBundleIdentifier: "app.oshell.mac").contains(where: { $0.processIdentifier != getpid() && $0.executableURL?.lastPathComponent == "OShell" }) {
                let deadline = Date().addingTimeInterval(3)
                while client == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.1); client = try? LaunchEndpoint.connect(directory: directory) }
                if client == nil { throw ModelError.invalid("已有 OShell 进程尚未提供启动服务，请退出旧版 OShell 并重新打开新版后重试。") }
            }
        }
        if client == nil {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            let appExecutable = applicationExecutable(from: executable)
            guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else { throw ModelError.invalid("请使用完整 OShell.app 中的启动文件。") }
            let app = Process(); app.executableURL = appExecutable; app.arguments = ["--external-launch-service"]
            app.standardInput = FileHandle.nullDevice; app.standardOutput = FileHandle.nullDevice; app.standardError = FileHandle.nullDevice
            try app.run()
            let deadline = Date().addingTimeInterval(12)
            while client == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1); client = try? LaunchEndpoint.connect(directory: directory)
            }
        }
        guard let fd = client else { throw ModelError.invalid("OShell 启动服务未就绪，请退出旧版 OShell 后重试。") }
        defer { close(fd) }
        if let terminal = request.terminal { try AuthIPC.write(terminal, fd: fd) }
        else { try AuthIPC.write(request, fd: fd) }
        let response = try AuthIPC.read(ZOCLaunchResponse.self, fd: fd)
        guard response.accepted else { throw ModelError.invalid(response.message) }
    }
}
