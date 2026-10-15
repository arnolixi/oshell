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
            status=SecKeychainFindGenericPassword(keychain,(UInt32)strlen(service),service,(UInt32)strlen(account),account,&size,&data,NULL);
            if (status==errSecSuccess && (size!=strlen(value) || memcmp(data,value,size))) status=errSecDecode;
        }
    }
    if (data) SecKeychainItemFreeContent(NULL,data);
    if (keychain) CFRelease(keychain);
    printf("%d %d\n", VERSION, (int)status);
    return status==errSecSuccess ? 0 : 1;
}
'''
def main():
    checks={}
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
        finally:
            if item_keychain.exists(): signing.run(['security','delete-keychain',item_keychain])
    report={'passed':all(checks.values()),'checks':checks}
    (signing.ROOT/'validation/signing-upgrade.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    return 0 if report['passed'] else 1
if __name__=='__main__': raise SystemExit(main())
