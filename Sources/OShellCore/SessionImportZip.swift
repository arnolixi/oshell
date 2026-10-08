// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors

import Foundation
import zlib

/// Reads bounded ZIP/XTS entries in memory. Never extracts paths onto disk.
enum SessionImportZip {
    struct Entry { let path: String; let data: Data; let directory: Bool }
    static func read(_ data: Data, check: () throws -> Void) throws -> [Entry] {
        func invalid(_ message: String = "XTS/ZIP 文件损坏或格式不受支持。") -> ModelError { .invalid(message) }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else { throw invalid() }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int { try u16(offset) | (u16(offset + 2) << 16) }
        guard data.count >= 22 else { throw invalid() }
        let lower = max(0, data.count - 65557)
        var end: Int?
        for offset in stride(from: data.count - 22, through: lower, by: -1) {
            if try u32(offset) == 0x06054b50, offset + 22 + (try u16(offset + 20)) == data.count { end = offset; break }
        }
        guard let end else { throw invalid("不是支持的 ZIP 结构 XTS。请在 Xshell 中恢复该导出包，再复制 Sessions 目录里的 .xsh 文件导入。") }
        let count = try u16(end + 10), size = try u32(end + 12), start = try u32(end + 16)
        guard try u16(end + 4) == 0, try u16(end + 6) == 0, try u16(end + 8) == count,
              count < 4001, count != 65535, size != 0xffffffff, start != 0xffffffff,
              start >= 0, size >= 0, start + size == end else { throw invalid("不支持分卷、ZIP64 或超过 4000 项的导出包。") }
        var cursor = start, total = 0, seen = Set<String>(), result = [Entry]()
        for _ in 0..<count {
            try check()
            guard try u32(cursor) == 0x02014b50 else { throw invalid() }
            let madeBy = try u16(cursor + 4), flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let checksum = try u32(cursor + 16), compressed = try u32(cursor + 20), expanded = try u32(cursor + 24)
            let nameLength = try u16(cursor + 28), extraLength = try u16(cursor + 30), commentLength = try u16(cursor + 32)
            let attributes = try u32(cursor + 38), local = try u32(cursor + 42)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard try u16(cursor + 34) == 0, nameLength > 0, nameLength <= 4096, next <= end,
                  compressed <= data.count, expanded <= 2 * 1024 * 1024, total + expanded <= ThirdPartySessionImporter.maximumBytes else { throw invalid("导出包大小或目录记录超出限制。") }
            guard flags & 1 == 0 else { throw invalid("导出包使用容器加密，暂不支持直接解密。请先在 Xshell 中恢复，再导入 .xsh 文件或 Sessions 目录。") }
            guard method == 0 || method == 8 else { throw invalid("导出包使用不支持的压缩算法；请先在 Xshell 中恢复并复制 .xsh 文件。") }
            let rawName = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            let name = try ThirdPartySessionImporter.decodeText(rawName)
            let normalized = try ThirdPartySessionImporter.relativePath(name, allowTrailingSlash: true)
            let isDirectory = name.hasSuffix("/") || name.hasSuffix("\\")
            let unixType = (attributes >> 16) & 0xf000
            guard (madeBy >> 8 != 3 || unixType == 0 || unixType == 0x8000 || unixType == 0x4000),
                  seen.insert(normalized.lowercased()).inserted else { throw invalid("导出包含符号链接、特殊文件或重复路径。") }
            guard try u32(local) == 0x04034b50, try u16(local + 6) == flags, try u16(local + 8) == method else { throw invalid() }
            let localNameLength = try u16(local + 26), localExtraLength = try u16(local + 28)
            let content = local + 30 + localNameLength + localExtraLength
            guard content <= start, content + compressed <= start, localNameLength == nameLength,
                  data.subdata(in: local + 30..<local + 30 + localNameLength) == rawName else { throw invalid() }
            total += expanded; cursor = next
            // Other exported settings are neither interpreted nor written to disk.
            guard isDirectory || normalized.lowercased().hasSuffix(".xsh") else { continue }
            let source = data.subdata(in: content..<content + compressed)
            let decoded: Data
            if method == 0 { guard compressed == expanded else { throw invalid() }; decoded = source }
            else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid() }
                defer { inflateEnd(&stream) }
                var buffer = [UInt8](repeating: 0, count: expanded + 1)
                let capacity = buffer.count
                let status = source.withUnsafeBytes { input in buffer.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = uInt(source.count)
                    stream.next_out = output.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = uInt(capacity)
                    return inflate(&stream, Z_FINISH)
                } }
                guard status == Z_STREAM_END, stream.total_out == expanded, stream.total_in == compressed else { throw invalid("导出包解压长度不符或内容损坏。") }
                decoded = Data(buffer.prefix(expanded))
            }
            let actual = decoded.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(decoded.count)) }
            guard Int(actual) == checksum else { throw invalid("导出包校验失败；请重新从 Xshell 导出。") }
            result.append(.init(path: normalized, data: decoded, directory: isDirectory))
        }
        guard cursor == end else { throw invalid() }
        return result
    }
}
