// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit

enum RemoteFileMetadataTest {
    static func run(_ controller: WorkspaceController) {
        var checks: [String: Bool] = [:]
        do {
            checks["regularPermissions"] = RemoteFilePermissions.display(0o100644) == "-rw-r--r-- (0644)"
            checks["directoryPermissions"] = RemoteFilePermissions.display(0o041755) == "drwxr-xr-t (1755)"
            checks["specialBitsWithoutExecute"] = RemoteFilePermissions.display(0o107644) == "-rwSr-Sr-T (7644)"
            checks["symlink"] = RemoteFilePermissions.display(0o120777) == "lrwxrwxrwx (0777)"
            checks["allPermissionBitsRoundTrip"] = (UInt32(0)...0o7777).allSatisfy { bits in
                RemoteFilePermissions.symbolic(String(RemoteFilePermissions.display(0x8000 | bits).prefix(10))) == 0x8000 | bits
            }
            checks["malformedPermissionsRejected"] = ["", "-rwwr--r--", "-rwtr--r--", "drwxr-xr-s"].allSatisfy { RemoteFilePermissions.symbolic($0) == nil }
            checks["octalValidation"] = RemoteFilePermissions.octal("0000") == 0 && RemoteFilePermissions.octal("4755") == 0o4755 && ["888", "-644", "rwx", "100644", "644 "].allSatisfy { RemoteFilePermissions.octal($0) == nil }
            func packet(_ flags: UInt32 = 15, mode: UInt32 = 0o100640) -> SFTPPacket {
                var p = SFTPPacket(); p.u32(flags)
                if flags & 1 != 0 { p.u64(12) }
                if flags & 2 != 0 { p.u32(0); p.u32(1001) }
                if flags & 4 != 0 { p.u32(mode) }
                if flags & 8 != 0 { p.u32(10); p.u32(20) }
                if flags & 0x80000000 != 0 { p.u32(1); p.string("ignored"); p.string("value") }
                return p
            }
            var all = packet(0x8000000f)
            let numeric = try all.attributes(name: "a b.txt")
            checks["numericOwnerAndGroup"] = numeric.owner == "0" && numeric.group == "1001" && numeric.permissionsText == "-rw-r----- (0640)"
            checks["attributePacketAlignment"] = all.offset == all.data.count && numeric.size == 12 && numeric.modified == Date(timeIntervalSince1970: 20)
            var named = packet()
            let readable = try named.attributes(name: "a b.txt", longName: "-rw-r----- 1 deploy operators 12 Oct 13 09:00 a b.txt")
            checks["SFTPLongNameOwners"] = readable.owner == "deploy" && readable.group == "operators" && readable.permissions == numeric.permissions
            for longName in ["unstructured server text", "-rwx------ 1 incorrect wrong 12 Oct 13 09:00 a b.txt"] {
                var p = packet(); let fallback = try p.attributes(name: "a b.txt", longName: longName)
                checks["fallback-" + longName] = fallback.owner == "0" && fallback.group == "1001"
            }
            for flags: UInt32 in [0, 1, 2, 4, 8, 15] {
                var p = packet(flags, mode: 0); let e = try p.attributes(name: "zero")
                checks["optionalAttributes-\(flags)"] = p.offset == p.data.count && (e.permissions != nil) == (flags & 4 != 0) && (e.owner != nil) == (flags & 2 != 0)
            }
            var truncated = SFTPPacket(); truncated.u32(2); truncated.u32(0)
            do { _ = try truncated.attributes(name: "broken"); checks["truncatedPacketRejected"] = false } catch { checks["truncatedPacketRejected"] = true }
            let mlsd = try FTPBackend.parseMLSD(Data("type=file;size=12;UNIX.mode=0640;UNIX.owner=deploy;UNIX.group=operators; a b.txt\r\ntype=dir;UNIX.mode=1777;UNIX.uid=0;UNIX.gid=0; shared\r\ntype=file;perm=rw; plain\r\ntype=file;unix.mode=invalid; broken\r\n".utf8))
            checks["MLSDNamesAndMode"] = mlsd[0].owner == "deploy" && mlsd[0].group == "operators" && mlsd[0].permissionsText == "-rw-r----- (0640)" && mlsd[0].name == "a b.txt"
            checks["MLSDNumericFallback"] = mlsd[1].owner == "0" && mlsd[1].group == "0" && mlsd[1].permissionsText == "drwxrwxrwt (1777)"
            checks["FTPPermFactIsNotPOSIXMode"] = mlsd[2].permissions == nil && mlsd[2].owner == nil && mlsd[2].group == nil
            checks["invalidMLSDMode"] = mlsd[3].permissionsText == "—"
            let list = try FTPBackend.parseLIST(Data("-rwsr-xr-x+ 1 deploy operators 12 Oct 13 09:00 a b.txt\r\nlrwxrwxrwx 1 root wheel 4 Oct 13 2026 link -> dest\r\n".utf8))
            checks["LISTNamesAndMode"] = list[0].owner == "deploy" && list[0].group == "operators" && list[0].permissionsText == "-rwsr-xr-x (4755)" && list[0].name == "a b.txt"
            checks["LISTSymlink"] = list[1].symbolicLink && list[1].name == "link" && list[1].owner == "root" && list[1].permissions == 0o120777
            let dos = try FTPBackend.parseLIST(Data("10-13-26  08:00AM       <DIR>          folder name\r\n".utf8))
            checks["DOSMissingFields"] = dos[0].directory && dos[0].permissionsText == "—" && dos[0].owner == nil && dos[0].group == nil
        } catch { checks["unexpectedError"] = false }
        controller.shutdown()
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        let path = ProcessInfo.processInfo.environment["OSHELL_FILE_METADATA_OUTPUT"] ?? "/tmp/oshell-file-metadata.json"
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }
}
