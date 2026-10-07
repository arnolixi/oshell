#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Initialize/reuse an Ed25519 release key in a private file, never the Keychain."""
import argparse,base64,os,pathlib,plistlib
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
ROOT=pathlib.Path(__file__).resolve().parent.parent
PRIVATE=ROOT/'.release-private/sparkle-ed25519.key'
def public_key(path):
    seed=base64.b64decode(path.read_bytes(),validate=True)
    if len(seed)!=32: raise ValueError('Expected a 32-byte Ed25519 seed')
    return base64.b64encode(Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
def initialize():
    info_path=ROOT/'scripts/Info.plist';info=plistlib.loads(info_path.read_bytes())
    if not PRIVATE.exists():
        if info.get('SUPublicEDKey'): raise SystemExit('Signing key missing. Restore the original private key; refusing to replace the pinned public key.')
        PRIVATE.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        fd=os.open(PRIVATE,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as out: out.write(base64.b64encode(os.urandom(32)))
    if PRIVATE.is_symlink() or PRIVATE.stat().st_mode & 0o077: raise SystemExit('Private key must be a non-symlink private file (0600)')
    pub=public_key(PRIVATE)
    if info.get('SUPublicEDKey') not in [None,pub]: raise SystemExit('Private key does not match the embedded public key')
    info['SUPublicEDKey']=pub;info_path.write_bytes(plistlib.dumps(info,sort_keys=False))
    print('Release signing key ready; public key pinned. No private key printed.')
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--initialize',action='store_true',required=True);parser.parse_args();initialize()
