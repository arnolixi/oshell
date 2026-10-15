#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""One-time identity creation. Never called by builds or CI; refuses replacement."""
import datetime, hashlib, json, os, secrets
from code_signing import PRIVATE, PROFILE

def initialize():
    if PRIVATE.exists() or PROFILE.exists(): raise RuntimeError('An identity or pin already exists; restore it instead of rotating it.')
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import pkcs12
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
    os.umask(0o077); PRIVATE.mkdir(parents=True, mode=0o700)
    key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'OShell Code Signing')])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now-datetime.timedelta(minutes=5)).not_valid_after(now+datetime.timedelta(days=7300))
            .add_extension(x509.BasicConstraints(ca=False,path_length=None),critical=True)
            .add_extension(x509.KeyUsage(digital_signature=True,content_commitment=False,key_encipherment=False,data_encipherment=False,key_agreement=False,key_cert_sign=False,crl_sign=False,encipher_only=None,decipher_only=None),critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CODE_SIGNING]),critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()),critical=False).sign(key,hashes.SHA256()))
    password = secrets.token_urlsafe(48)
    encryption = (serialization.PrivateFormat.PKCS12.encryption_builder().kdf_rounds(100000)
                  .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC).hmac_hash(hashes.SHA1()).build(password.encode()))
    data = pkcs12.serialize_key_and_certificates(b'OShell Code Signing', key, cert, None, encryption)
    (PRIVATE/'identity.p12').write_bytes(data); (PRIVATE/'password').write_text(password+'\n')
    der = cert.public_bytes(serialization.Encoding.DER)
    PROFILE.write_text(json.dumps({'format':'OShell.code-signing.v1','name':'OShell Code Signing','sha1':hashlib.sha1(der).hexdigest(),'sha256':hashlib.sha256(der).hexdigest(),'expires':cert.not_valid_after_utc.isoformat()},indent=2)+'\n')
    PROFILE.chmod(0o644)
    print('Created encrypted local signing identity and public fingerprint pin. No private data printed.')
if __name__ == '__main__': initialize()
