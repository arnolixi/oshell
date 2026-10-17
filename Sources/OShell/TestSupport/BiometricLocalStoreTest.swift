// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 OShell contributors
import AppKit
import Security
import OShellCore

enum BiometricLocalStoreTest {
    private final class Legacy: BiometricRecordStore {
        var value:Data?, reads = 0, writes = 0, removes = 0, denied = false
        func read(account:String) throws -> Data { reads += 1; guard !denied, let value else { throw ModelError.invalid("fixture denied") }; return value }
        func write(_ data:Data,account:String) throws { writes += 1; value = data }
        func remove(account:String) throws { removes += 1; if denied { throw ModelError.invalid("fixture denied") }; value = nil }
    }
    static func run(_ workspace:WorkspaceController) {
        var checks=[String:Bool]()
        let base=workspace.store.url.deletingLastPathComponent().appendingPathComponent("biometric-record-test")
        let directory=base.appendingPathComponent("TouchID"), legacy=Legacy()
        let store=BiometricLocalStore(directory:directory,legacy:legacy)
        let scope=String(repeating:"a",count:64), other=String(repeating:"b",count:64)
        let file=directory.appendingPathComponent(scope+".json")
        func rejects(_ name:String,_ body:()throws->Void) { do { try body(); checks[name]=false } catch { checks[name]=true } }
        do {
            let fixture=try JSONEncoder().encode(BiometricEnvelope(version:1,scope:scope,sealedKey:Data([1]),peer:Data(repeating:2,count:65),salt:Data(repeating:3,count:32),ciphertext:Data(repeating:4,count:32)))
            legacy.value=fixture
            checks["silentMigrationKeepsEnvelope"] = try store.read(account:scope) == fixture
            checks["migrationReadsOnlyOnce"] = legacy.reads == 1 && legacy.writes == 0 && legacy.removes == 0
            checks["localRecordSurvivesNewInstance"] = try BiometricLocalStore(directory:directory,legacy:legacy).read(account:scope) == fixture && legacy.reads == 1
            checks["privateDirectory"] = (try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700
            checks["privateFile"] = (try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
            checks["excludedFromBackup"] = try directory.resourceValues(forKeys:[.isExcludedFromBackupKey]).isExcludedFromBackup == true
            rejects("rejectPlaintextWrite") { try store.write(Data("master-fixture-plaintext".utf8),account:scope) }
            rejects("rejectCrossScopeWrite") { try store.write(fixture,account:other) }
            checks["rejectedWritePreservesRecord"] = try Data(contentsOf:file) == fixture
            rejects("rejectTraversal") { _ = try store.read(account:"../record") }
            legacy.denied=true
            checks["localReadDoesNotTouchDeniedKeychain"] = try store.read(account:scope) == fixture && legacy.reads == 1
            try store.write(fixture,account:scope)
            checks["reenrollmentNeverWritesKeychain"] = legacy.writes == 0 && legacy.reads == 1
            try PrivateFile.write(Data("corrupt".utf8),to:file)
            rejects("corruptLocalRecordDoesNotFallback") { _ = try store.read(account:scope) }
            checks["corruptRecordPreserved"] = try Data(contentsOf:file) == Data("corrupt".utf8) && legacy.reads == 1
            try store.write(fixture,account:scope)
            try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:file.path)
            rejects("rejectBroadFilePermissions") { _ = try store.read(account:scope) }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            let target=base.appendingPathComponent("outside.json");try PrivateFile.write(fixture,to:target)
            try FileManager.default.removeItem(at:file);try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
            rejects("rejectSymlinkRead") { _ = try store.read(account:scope) }
            try store.write(fixture,account:scope)
            checks["writeReplacesLinkNotTarget"] = try Data(contentsOf:target) == fixture && (file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == false)
            let linkedRoot=base.appendingPathComponent("linked-root");try FileManager.default.createSymbolicLink(at:linkedRoot,withDestinationURL:directory)
            rejects("rejectSymlinkDirectory") { _ = try BiometricLocalStore(directory:linkedRoot,legacy:legacy).read(account:scope) }
            rejects("disableReportsDeniedLegacyCleanup") { try store.remove(account:scope) }
            checks["disableDeletesLocalDespiteLegacyDenial"] = !FileManager.default.fileExists(atPath:file.path)
            rejects("deniedMigrationRequiresReenrollment") { _ = try store.read(account:scope) }
            checks["deniedMigrationCreatesNoRecord"] = !FileManager.default.fileExists(atPath:file.path)
            legacy.denied=false;legacy.value=fixture
            _ = try store.read(account:scope);try store.remove(account:scope)
            checks["explicitDisableCleansBothStores"] = !FileManager.default.fileExists(atPath:file.path) && legacy.value == nil
            let actual=BiometricKeychainStore(service:"app.oshell.noninteractive-fixture."+UUID().uuidString)
            var before=DarwinBoolean(false), after=DarwinBoolean(false)
            _ = SecKeychainGetUserInteractionAllowed(&before)
            _ = try? actual.read(account:scope)
            _ = SecKeychainGetUserInteractionAllowed(&after)
            checks["legacyReadRestoresInteractionState"] = before.boolValue == after.boolValue
            _ = try? actual.remove(account:scope)
            _ = SecKeychainGetUserInteractionAllowed(&after)
            checks["legacyRemoveRestoresInteractionState"] = before.boolValue == after.boolValue
        } catch { checks["unexpectedError"]=false;print("Local biometric store test error:",(error as NSError).domain,(error as NSError).code) }
        let report:[String:Any]=["passed":checks.values.allSatisfy { $0 },"checks":checks]
        if let path=ProcessInfo.processInfo.environment["OSHELL_BIOMETRIC_LOCAL_OUTPUT"] { try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path)) }
        workspace.shutdown();NSApp.terminate(nil)
    }
}
