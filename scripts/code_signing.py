# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Pinned, stable macOS signing identity. Private material never enters build logs."""
import base64, contextlib, hashlib, json, os, pathlib, plistlib, re, secrets, shlex, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
PROFILE = ROOT/'scripts/code-signing.json'
PRIVATE = ROOT/'.release-private/code-signing'
MARKER = 'OShellCodeSigningCertificateSHA256'

def run(args, **kwargs):
    result = subprocess.run(list(map(str, args)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        # security arguments can contain passwords; never include argv or its output.
        detail = result.stderr.decode(errors='replace').strip() if pathlib.Path(str(args[0])).name == 'codesign' else str(args[1])
        raise RuntimeError(f'{pathlib.Path(str(args[0])).name} failed (exit {result.returncode}): {detail}')
    return result.stdout

def profile():
    value = json.loads(PROFILE.read_text())
    if value.get('format') != 'OShell.code-signing.v1' or not re.fullmatch('[0-9a-f]{40}', value.get('sha1','')) or not re.fullmatch('[0-9a-f]{64}', value.get('sha256','')):
        raise ValueError('Invalid public code signing profile')
    return value

def requirement(identifier, pin):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', identifier) or not re.fullmatch('[0-9a-f]{40}', pin):
        raise ValueError('Invalid signing identifier or certificate fingerprint')
    return f'identifier "{identifier}" and certificate leaf = H"{pin}"'

def metadata(info):
    value = info.get(MARKER)
    return {'signing': 'self-signed' if value else 'ad-hoc', 'codeSigningCertificateSHA256': value}

@contextlib.contextmanager
def identity():
    pin = profile()
    encoded, password = os.environ.get('OSHELL_CODESIGN_P12'), os.environ.get('OSHELL_CODESIGN_PASSWORD')
    if encoded is not None or password is not None:
        if not encoded or not password: raise ValueError('Both OSHELL_CODESIGN_P12 and OSHELL_CODESIGN_PASSWORD are required')
        p12 = base64.b64decode(encoded, validate=True)
    else:
        if not (PRIVATE/'identity.p12').is_file() or not (PRIVATE/'password').is_file():
            raise ValueError('Fixed signing credentials missing. Restore the original private identity; do not generate a new certificate. Development-only ad-hoc builds require OSHELL_ALLOW_ADHOC=1.')
        p12 = (PRIVATE/'identity.p12').read_bytes(); password = (PRIVATE/'password').read_text().strip()
    with tempfile.TemporaryDirectory(prefix='oshell-sign-') as raw:
        folder = pathlib.Path(raw); bundle = folder/'identity.p12'; bundle.write_bytes(p12); bundle.chmod(0o600)
        env = dict(os.environ, OSHELL_P12_PASSWORD_INPUT=password)
        pem = run(['openssl','pkcs12','-in',bundle,'-clcerts','-nokeys','-passin','env:OSHELL_P12_PASSWORD_INPUT'], env=env)
        certificate = run(['openssl','x509','-outform','DER'], input=pem)
        if hashlib.sha256(certificate).hexdigest() != pin['sha256'] or hashlib.sha1(certificate).hexdigest() != pin['sha1']:
            raise ValueError('Signing certificate does not match the pinned public identity')
        keychain = folder/'signing.keychain-db'; key_password = secrets.token_urlsafe(32)
        # codesign's explicit --keychain does not replace the user search list
        # used while resolving the identity/certificate chain on older runners.
        previous_search = shlex.split(run(['security','list-keychains','-d','user']).decode())
        try:
            run(['security','create-keychain','-p',key_password,keychain])
            run(['security','set-keychain-settings','-lut','21600',keychain])
            run(['security','unlock-keychain','-p',key_password,keychain])
            run(['security','import',bundle,'-k',keychain,'-P',password,'-T','/usr/bin/codesign'])
            run(['security','set-key-partition-list','-S','apple-tool:,apple:','-s','-k',key_password,keychain])
            run(['security','list-keychains','-d','user','-s',keychain,*previous_search])
            matching = run(['security','find-identity','-p','codesigning',keychain]).decode(errors='replace').strip()
            # A deliberately self-signed certificate is not an Apple-trusted
            # identity. Match the imported certificate/private-key pair without
            # -v, then let the actual signing probe validate its usability.
            if pin['sha1'].upper() not in matching.upper():
                raise RuntimeError('Pinned certificate/private-key pair missing after import: '+matching)
            yield keychain, pin
        finally:
            try: run(['security','list-keychains','-d','user','-s',*previous_search])
            finally:
                if keychain.exists(): run(['security','delete-keychain',keychain])

def sign_path(path, keychain, pin, identifier):
    run(['codesign','--force','--sign',pin['sha1'],'--keychain',keychain,'--timestamp=none','--identifier',identifier,
         '--requirements','=designated => '+requirement(identifier,pin['sha1']),path])

def macho(path):
    if path.is_symlink() or not path.is_file(): return False
    with path.open('rb') as stream: return stream.read(4) in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')

def verify(app):
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes()); pin = profile()
    if info.get(MARKER) != pin['sha256']: raise ValueError('App is missing the pinned signing identity')
    run(['codesign','--verify','--deep','--strict','-R','='+requirement(info['CFBundleIdentifier'],pin['sha1']),app])
    with tempfile.TemporaryDirectory(prefix='oshell-cert-') as raw:
        prefix = pathlib.Path(raw)/'certificate'
        run(['codesign','--display','--extract-certificates='+str(prefix),app])
        if hashlib.sha256(prefix.with_name(prefix.name+'0').read_bytes()).hexdigest() != pin['sha256']:
            raise ValueError('App leaf certificate mismatch')
    return metadata(info)

def sign_app(app):
    path = app/'Contents/Info.plist'; info = plistlib.loads(path.read_bytes())
    adhoc = info.get('OShellTestHarness') is True or os.environ.get('OSHELL_ALLOW_ADHOC') == '1'
    if adhoc:
        if os.environ.get('OSHELL_REQUIRE_FIXED_SIGNING') == '1': raise ValueError('Official builds require the fixed signing identity')
        info.pop(MARKER,None); path.write_bytes(plistlib.dumps(info))
        run(['codesign','--force','--sign','-',app])
        run(['codesign','--verify','--deep','--strict',app]); return metadata(info)
    with identity() as (keychain,pin):
        info[MARKER] = pin['sha256']; path.write_bytes(plistlib.dumps(info))
        for item in sorted(app.rglob('*')):
            if macho(item):
                identifier = 'app.oshell.code.' + re.sub(r'[^A-Za-z0-9_.-]', '-', item.name)
                sign_path(item,keychain,pin,identifier)
        bundles = sorted((p for p in app.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ('.app','.xpc','.framework')), key=lambda p:len(p.parts), reverse=True)
        for bundle in bundles + [app]:
            plist = bundle/'Contents/Info.plist'
            if bundle.suffix == '.framework': plist = bundle/'Resources/Info.plist'
            bundle_info = plistlib.loads(plist.read_bytes())
            sign_path(bundle,keychain,pin,bundle_info['CFBundleIdentifier'])
        return verify(app)


def preflight():
    """Exercise the actual identity before spending minutes compiling an app."""
    with identity() as (keychain, pin), tempfile.TemporaryDirectory(prefix='oshell-sign-probe-') as raw:
        folder = pathlib.Path(raw); source = folder/'probe.c'; binary = folder/'probe'
        source.write_text('int main(void) { return 0; }\n')
        run(['xcrun','clang',source,'-o',binary])
        identifier = 'app.oshell.signing-preflight'
        sign_path(binary,keychain,pin,identifier)
        run(['codesign','--verify','--strict','-R','='+requirement(identifier,pin['sha1']),binary])
        return {'preflight':'passed','signing':'self-signed','codeSigningCertificateSHA256':pin['sha256']}
