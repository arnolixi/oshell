#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""macOS-only: two distinct binaries access one disposable keychain item through a stable DR.
User interaction is disabled; no login-keychain items or biometric bindings are read.
"""
import json, pathlib, secrets, shutil, subprocess, tempfile
import code_signing as signing
SOURCE = r'''
#include <Security/Security.h>
#include <stdio.h>
#include <string.h>
#ifndef VERSION
#define VERSION 1
#endif
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    SecKeychainSetUserInteractionAllowed(false);
    SecKeychainRef keychain = NULL;
    OSStatus status = SecKeychainOpen(argv[1], &keychain);
    const char *service="OShell.Signing.Upgrade.Fixture", *account="fixture", *value="disposable-fixture-data";
    UInt32 size=0; void *data=NULL;
    if (status==errSecSuccess) {
        if (strcmp(argv[2],"create")==0) status=SecKeychainAddGenericPassword(keychain,(UInt32)strlen(service),service,(UInt32)strlen(account),account,(UInt32)strlen(value),value,NULL);
        else {
            // Match the production SecItem legacy-keychain query path.
            const void *chains[]={keychain};
            CFArrayRef search=CFArrayCreate(NULL,chains,1,&kCFTypeArrayCallBacks);
            const void *keys[]={kSecClass,kSecAttrService,kSecAttrAccount,kSecReturnData,kSecMatchLimit,kSecMatchSearchList,kSecUseDataProtectionKeychain,kSecUseAuthenticationUI};
            const void *values[]={kSecClassGenericPassword,CFSTR("OShell.Signing.Upgrade.Fixture"),CFSTR("fixture"),kCFBooleanTrue,kSecMatchLimitOne,search,kCFBooleanFalse,kSecUseAuthenticationUIFail};
            CFDictionaryRef query=CFDictionaryCreate(NULL,keys,values,8,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
            CFTypeRef result=NULL; status=SecItemCopyMatching(query,&result);
            if (status==errSecSuccess && (!result || CFGetTypeID(result)!=CFDataGetTypeID() || CFDataGetLength((CFDataRef)result)!=strlen(value) || memcmp(CFDataGetBytePtr((CFDataRef)result),value,strlen(value)))) status=errSecDecode;
            if (result) CFRelease(result);
            CFRelease(query); CFRelease(search);
        }
    }
    if (data) SecKeychainItemFreeContent(NULL,data);
    if (keychain) CFRelease(keychain);
    printf("%d %d\n", VERSION, (int)status);
    return status==errSecSuccess ? 0 : 1;
}
'''
def main():
    checks={}; observations={}
    with tempfile.TemporaryDirectory(prefix='oshell-upgrade-') as raw:
        root=pathlib.Path(raw); source=root/'fixture.c';source.write_text(SOURCE)
        v1=root/'v1'; v2=root/'v2'; installed=root/'current'; item_keychain=root/'items.keychain-db'; password=secrets.token_urlsafe(32)
        for index,binary in enumerate([v1,v2],1):
            signing.run(['clang',source,'-DVERSION='+str(index),'-framework','Security','-framework','CoreFoundation','-o',binary])
        with signing.identity() as (keychain,pin):
            for binary in [v1,v2]: signing.sign_path(binary,keychain,pin,'app.oshell.signing-upgrade-fixture')
        def signature(binary):
            result=subprocess.run(['codesign','-d','-r-',str(binary)],capture_output=True,text=True,check=True)
            return (result.stdout+result.stderr).split('designated => ',1)[1].splitlines()[0].strip()
        checks['identicalDesignatedRequirement']=signature(v1)==signature(v2)
        checks['differentSignedBinaries']=v1.read_bytes()!=v2.read_bytes()
        try:
            signing.run(['security','create-keychain','-p',password,item_keychain])
            signing.run(['security','unlock-keychain','-p',password,item_keychain])
            shutil.copy2(v1,installed)
            signing.run([installed,item_keychain,'create']); checks['originalCreatesProtectedItem']=True
            signing.run([installed,item_keychain,'read']); checks['originalReadsWithoutPrompt']=True
            # Replace inode as an updater does; do not mutate a running signed executable.
            installed.unlink(); shutil.copy2(v2,installed)
            signing.run([installed,item_keychain,'read']); checks['updateReadsWithoutPrompt']=True
            other=root/'other'; shutil.copy2(v2,other)
            signing.run(['codesign','--force','--sign','-','--identifier','app.oshell.signing-upgrade-fixture',other])
            installed.unlink(); shutil.copy2(other,installed)
            denied=subprocess.run([str(installed),str(item_keychain),'read'],capture_output=True,text=True,timeout=10)
            fields=denied.stdout.strip().split()
            checks['sameIdentifierWrongSignerDenied']=denied.returncode==1 and len(fields)==2 and fields[0]=='2' and int(fields[1]) in (-25293,-25308)
            # A real legacy login-keychain item can additionally restrict the
            # caller's changing cdhash. A stable DR alone cannot override it.
            details=subprocess.run(['codesign','-d','--verbose=4',str(v1)],capture_output=True,text=True,check=True)
            old_hash=next(line.split('=',1)[1] for line in (details.stdout+details.stderr).splitlines() if line.startswith('CDHash='))
            signing.run(['security','set-generic-password-partition-list','-a','fixture','-s','OShell.Signing.Upgrade.Fixture','-S','cdhash:'+old_hash,'-k',password,item_keychain])
            installed.unlink(); shutil.copy2(v2,installed)
            partition_denied=subprocess.run([str(installed),str(item_keychain),'read'],capture_output=True,text=True,timeout=10)
            fields=partition_denied.stdout.strip().split()
            checks['partitionProbeCompletesWithoutInteraction']=len(fields)==2 and fields[0]=='2' and int(fields[1]) in (0,-25293,-25308)
            # Private temporary keychains do not necessarily enforce the same
            # partition behavior as an existing login keychain. Record evidence,
            # do not claim that this proves universal upgrade authorization.
            observations['temporaryPartitionReadStatus']=int(fields[1]) if len(fields)==2 else None
        finally:
            if item_keychain.exists(): signing.run(['security','delete-keychain',item_keychain])
    report={'passed':all(checks.values()),'checks':checks,'observations':observations}
    (signing.ROOT/'validation/signing-upgrade.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    return 0 if report['passed'] else 1
if __name__=='__main__': raise SystemExit(main())
