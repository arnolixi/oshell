// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import OShellCore

/// Bounded lifecycle diagnostics: no host, credentials, filenames or payload.
enum TransferDiagnostics {
    private static let queue = DispatchQueue(label: "OShell.transfer.diagnostics", qos: .utility)
    static func record(_ event: String) {
        queue.async {
            let root: URL
            if let path = ProcessInfo.processInfo.environment["OSHELL_DATA_DIR"] { root = URL(fileURLWithPath: path) }
            else { root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OShell") }
            let file = root.appendingPathComponent("transfer-diagnostics.log")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var data = (try? Data(contentsOf: file)) ?? Data()
                if data.count > 48 * 1024 { data = Data(data.suffix(32 * 1024)) }
                data.append(Data((event + "\n").utf8))
                try PrivateFile.write(data, to: file)
            } catch { /* Diagnostic I/O never delays or cancels a transfer. */ }
        }
    }
}
