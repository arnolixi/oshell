#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Read-only package/image validation. Does not install or launch the payload."""
import argparse,hashlib,json,pathlib,plistlib,re,subprocess,tempfile,xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parent.parent
out=root/'dist/installers';version=plistlib.loads((root/'scripts/Info.plist').read_bytes())['CFBundleShortVersionString']
parser=argparse.ArgumentParser()
parser.add_argument('--flavor',action='append',choices=['modern','arm64','legacy'])
args=parser.parse_args()
results=[]
def run(args):return subprocess.run(list(map(str,args)),capture_output=True,text=True,check=True).stdout
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
for flavor,suffix,minimum,arches in [('modern','macOS13-Universal','13.0',{'arm64','x86_64'}),('arm64','macOS13-arm64','13.0',{'arm64'}),('legacy','macOS10.13-Intel','10.13',{'x86_64'})]:
    if args.flavor and flavor not in args.flavor: continue
    staged=root/'work/release'/flavor/'OShell.app'
    pkg=out/f'OShell-{version}-{suffix}.pkg';dmg=out/f'OShell-{version}-{suffix}.dmg'
    with tempfile.TemporaryDirectory(prefix='oshell-installer-verify-',dir='/tmp') as directory:
        temporary=pathlib.Path(directory);expanded=temporary/'expanded'
        run(['pkgutil','--expand-full',pkg,expanded])
        app=next(expanded.rglob('OShell.app'))
        distribution=ET.parse(expanded/'Distribution').getroot()
        assert distribution.find('.//os-version').attrib['min']==minimum
        assert set(distribution.find('options').attrib['hostArchitectures'].split(','))==arches
        def check_app(candidate):
            info=plistlib.loads((candidate/'Contents/Info.plist').read_bytes())
            assert info['CFBundleShortVersionString']==version and info['LSMinimumSystemVersion']==minimum
            expected=plistlib.loads((root/'scripts/Info.plist').read_bytes())
            assert info['CFBundleVersion']==expected['CFBundleVersion']
            bridge=plistlib.loads((candidate/'Contents/Helpers/OShell-FileZilla.app/Contents/Info.plist').read_bytes())
            assert bridge['LSMinimumSystemVersion']==minimum
            if flavor=='legacy': assert (candidate/'Contents/Frameworks/libswiftCore.dylib').exists()
            for resource in ['OShell-LICENSE.txt','OShell.icns','oshell-integration.sh','THIRD_PARTY_NOTICES.txt','ColorSchemes-LICENSE.txt','Sparkle-LICENSE.txt']:
                assert digest(candidate/'Contents/Resources'/resource)==digest(staged/'Contents/Resources'/resource)
            for relative in ['MacOS/OShell','MacOS/OShell-ZOC','Helpers/OShellSSH','Helpers/OShellAskpass','Helpers/OShellProxy','Helpers/lrz','Helpers/lsz','Helpers/OShell-FileZilla.app/Contents/MacOS/OShell-FileZilla']:
                item=candidate/'Contents'/relative
                assert set(run(['lipo','-archs',item]).split())==arches,(relative,'wrong architecture')
                assert digest(item)==digest(staged/'Contents'/relative),(relative,'stale payload')
            # Check every Mach-O, including bundled Swift runtimes, not just plist claims.
            for item in (candidate/'Contents').rglob('*'):
                if not item.is_file() or item.is_symlink(): continue
                with item.open('rb') as f: magic=f.read(4)
                if magic not in [b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca']: continue
                assert set(run(['lipo','-archs',item]).split())==arches,(str(item),'wrong Mach-O architecture')
                build=run(['vtool','-show-build',item])
                deployment=re.findall(r'^\s*minos\s+(\d+(?:\.\d+)*)',build,re.M) + re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+)*)',build)
                assert deployment,(str(item),'missing deployment target')
                def parts(value): return tuple((list(map(int,value.split('.')))+[0,0,0])[:3])
                assert all(parts(value)<=parts(minimum) for value in deployment),(str(item),deployment,minimum)
            run(['codesign','--verify','--deep','--strict',candidate])
        check_app(app)
        mount=temporary/'mount';mount.mkdir()
        attached=False
        try:
            run(['hdiutil','attach','-nobrowse','-readonly','-mountpoint',mount,dmg]);attached=True
            check_app(mount/'OShell.app')
            assert (mount/'Applications').is_symlink()
        finally:
            if attached:run(['hdiutil','detach',mount])
        results.append({'flavor':flavor,'passed':True,'minimumOS':minimum,'architectures':sorted(arches),'pkg':pkg.name,'dmg':dmg.name,'payloadMatchesStagedApp':True,'signaturesVerified':True,'allMachOMinimumsVerified':True})
        print(flavor,'PKG and DMG payload checks passed',flush=True)
for line in (out/'SHA256SUMS.txt').read_text().splitlines():
    expected,name=line.split('  ',1);assert digest(out/name)==expected
(root/'validation/package-installers-verification.json').write_text(json.dumps({'passed':True,'packages':results},indent=2))
print('All checksums passed')
