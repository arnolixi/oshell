// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import Darwin

public extension FileHandle {
    func oshellWrite(contentsOf data: Data) throws {
        #if !OSHELL_LEGACY
        if #available(macOS 10.15.4, *) { try write(contentsOf: data); return }
        #endif
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
    }
    func oshellRead(upToCount count: Int) throws -> Data? {
        #if !OSHELL_LEGACY
        if #available(macOS 10.15.4, *) { return try read(upToCount: count) }
        #endif
        guard count >= 0 else { throw POSIXError(.EINVAL) }
        if count == 0 { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        var received: Int
        repeat { received = Darwin.read(fileDescriptor, &bytes, count) } while received < 0 && errno == EINTR
        guard received >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return received == 0 ? nil : Data(bytes.prefix(received))
    }
    func oshellClose() throws {
        #if OSHELL_LEGACY
        closeFile()
        #else
        if #available(macOS 10.15, *) { try close() } else { closeFile() }
        #endif
    }
    func oshellSynchronize() throws {
        #if !OSHELL_LEGACY
        if #available(macOS 10.15, *) { try synchronize(); return }
        #endif
        var result: Int32
        repeat { result = fsync(fileDescriptor) } while result < 0 && errno == EINTR
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
