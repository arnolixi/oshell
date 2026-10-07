#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Build modern Universal/arm64 and legacy Intel apps, then produce PKG and DMG files.
Never installs an app or replaces the developer's dist/OShell.app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / 'work/release'
OUT = ROOT / 'dist/installers'
LOG = ROOT / 'validation'
INFO = plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())
VERSION = INFO['CFBundleShortVersionString']
PROGRAMS = {'OShell':'MacOS/OShell', 'OShell-ZOC':'MacOS/OShell-ZOC',
    'OShell-FileZilla':'Helpers/OShell-FileZilla.app/Contents/MacOS/OShell-FileZilla',
    'OShellAskpass':'Helpers/OShellAskpass', 'OShellProxy':'Helpers/OShellProxy', 'OShellSSH':'Helpers/OShellSSH'}

def run(args, *, log=None, env=None, cwd=ROOT):
    if log:
        with (LOG/log).open('wb') as output:
            subprocess.run(list(map(str,args)),cwd=cwd,env=env,stdout=output,stderr=subprocess.STDOUT,check=True)
    else: subprocess.run(list(map(str,args)),cwd=cwd,env=env,check=True)

def output(args):
    return subprocess.check_output(list(map(str,args)),text=True).strip()

def build_swift(flavor, arch, minimum):
    base = ROOT / ('work/build-legacy' if flavor == 'legacy' else f'work/build-modern-{arch}')
    env = dict(os.environ, OSHELL_LEGACY='1' if flavor == 'legacy' else '0')
    args = ['swift','build','--package-path',ROOT,'--scratch-path',base/'swift','--cache-path',base/'cache',
        '--config-path',base/'config','--security-path',base/'security','--disable-sandbox','-c','release',
        '--triple',f'{arch}-apple-macosx{minimum}', '-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',
        '-Xlinker','-rpath','-Xlinker','@executable_path/../../../../Frameworks']
    args += ['-Xswiftc','-file-prefix-map','-Xswiftc',f'{ROOT}=/OShell','-Xswiftc','-debug-prefix-map','-Xswiftc',f'{ROOT}=/OShell','-Xswiftc','-file-compilation-dir','-Xswiftc','/OShell','-Xcc',f'-ffile-prefix-map={ROOT}=/OShell']
    if flavor == 'legacy': args += ['-Xswiftc','-DOSHELL_LEGACY']
    print('Building',flavor,arch,flush=True)
    run(args,env=env,log=f'package-{flavor}-{arch}-build.log')
    return base/'swift'/f'{arch}-apple-macosx'/'release'

def build_lrzsz(arch, minimum):
    base = WORK/f'lrzsz-{arch}-{minimum}'
    marker = base/'.built-public-paths'
    if not marker.exists():
        base.mkdir(parents=True,exist_ok=True)
        run(['tar','-xzf',ROOT/'Vendor/lrzsz-0.12.20.tar.gz','--strip-components=1','-C',base])
        env=dict(os.environ,CC='clang',CFLAGS=f'-arch {arch} -Os -mmacosx-version-min={minimum} -std=gnu89 -Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types -ffile-prefix-map={ROOT}=/OShell -fdebug-prefix-map={ROOT}=/OShell',LDFLAGS=f'-arch {arch} -mmacosx-version-min={minimum}')
        host='arm' if arch=='arm64' else 'x86_64'
        run(['./configure','--disable-nls','--disable-timesync',f'--host={host}-apple-darwin','--prefix=/usr'],cwd=base,env=env,log=f'package-lrzsz-{arch}-{minimum}-configure.log')
        run(['make','clean'],cwd=base,env=env,log=f'package-lrzsz-{arch}-{minimum}-clean.log')
        run(['make','-j4'],cwd=base,env=env,log=f'package-lrzsz-{arch}-{minimum}-build.log')
        marker.write_text('OShell reproducible helper build\n')
    return base/'src'

def macho(path):
    if not path.is_file() or path.is_symlink(): return False
    with path.open('rb') as f: return f.read(4) in [b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca']

def assemble(flavor, arches, minimum, binaries, helpers):
    app = WORK/flavor/'OShell.app'
    if app.exists(): shutil.rmtree(app)
    contents=app/'Contents'; resources=contents/'Resources'
    resources.mkdir(parents=True)
    for name, relative in PROGRAMS.items():
        target=contents/relative; target.parent.mkdir(parents=True,exist_ok=True)
        if len(arches)==1: shutil.copy2(binaries[arches[0]]/name,target)
        else: run(['lipo','-create',*[binaries[a]/name for a in arches],'-output',target])
    for name in ['lrz','lsz']:
        target=contents/'Helpers'/name
        if len(arches)==1: shutil.copy2(helpers[arches[0]]/name,target)
        else: run(['lipo','-create',*[helpers[a]/name for a in arches],'-output',target])
    (contents/'Helpers/rz').symlink_to('lrz'); (contents/'Helpers/sz').symlink_to('lsz')
    for bundle in binaries[arches[0]].glob('*.bundle'):
        shutil.copytree(bundle,resources/bundle.name)
    info=dict(INFO,LSMinimumSystemVersion=minimum)
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    bridge=contents/'Helpers/OShell-FileZilla.app'
    bridge_info=plistlib.loads((ROOT/'scripts/FileZilla-Info.plist').read_bytes());bridge_info['LSMinimumSystemVersion']=minimum
    (bridge/'Contents/Info.plist').write_bytes(plistlib.dumps(bridge_info))
    for source,name in [(ROOT/'LICENSE','OShell-LICENSE.txt'),(ROOT/'THIRD_PARTY_NOTICES.txt','THIRD_PARTY_NOTICES.txt'),(ROOT/'Vendor/SwiftTerm/LICENSE','SwiftTerm-LICENSE.txt'),(helpers[arches[0]].parent/'COPYING','lrzsz-COPYING.txt'),(ROOT/'Vendor/lrzsz-0.12.20.tar.gz','lrzsz-0.12.20.tar.gz')]: shutil.copy2(source,resources/name)
    if flavor=='legacy': shutil.copy2(ROOT/'Vendor/CryptoSwift/LICENSE',resources/'CryptoSwift-LICENSE.txt')
    shutil.copy2(ROOT/'shell-integration/oshell-integration.sh',resources/'oshell-integration.sh')
    shutil.copy2(ROOT/'Vendor/ColorSchemes/LICENSE',resources/'ColorSchemes-LICENSE.txt')
    # Generate from the canonical drawing code, never reuse an older app icon.
    run(['swift',ROOT/'scripts/icon.swift',WORK/'OShell.iconset'])
    run(['iconutil','-c','icns',WORK/'OShell.iconset','-o',resources/'OShell.icns'])
    if flavor=='legacy':
        frameworks=contents/'Frameworks';frameworks.mkdir()
        runtime=Path(output(['xcrun','--find','swiftc'])).parent.parent/'lib/swift-5.0/macosx'
        run(['xcrun','swift-stdlib-tool','--copy','--scan-folder',contents,'--platform','macosx','--source-libraries',runtime,'--destination',frameworks],log='package-legacy-runtime.log')
        assert (frameworks/'libswiftCore.dylib').exists(), 'Missing pre-Swift-OS runtime'
    entries=[]
    for path in sorted(contents.rglob('*')):
        if not macho(path):continue
        actual=output(['lipo','-archs',path]).split()
        assert set(arches).issubset(actual),(path,actual)
        if flavor=='legacy' and len(actual)>1:
            thin=path.with_suffix(path.suffix+'.thin')
            run(['lipo',path,'-thin','x86_64','-output',thin]);thin.replace(path)
        if path.relative_to(contents).parts[0] != 'Frameworks':
            run(['xcrun','strip','-S',path],log='package-strip-last.log')
        if path != contents/'MacOS/OShell':
            run(['codesign','--force','--sign','-',path],log='package-codesign-last.log')
        entries.append({'path':str(path.relative_to(app)),'architectures':arches,'build':output(['vtool','-show-build',path]),'libraries':output(['otool','-L',path])})
    run(['codesign','--force','--sign','-',bridge],log='package-codesign-last.log')
    run(['python3',ROOT/'scripts/embed-sparkle.py',app,*arches],log=f'package-{flavor}-sparkle.log')
    run(['codesign','--force','--sign','-',app],log='package-codesign-last.log')
    run(['codesign','--verify','--deep','--strict',app])
    for path in (contents/'Frameworks/Sparkle.framework').rglob('*'):
        if macho(path): entries.append({'path':str(path.relative_to(app)),'architectures':arches,'build':output(['vtool','-show-build',path]),'libraries':output(['otool','-L',path])})
    run(['python3',ROOT/'scripts/check-public-source.py','--app',app],log=f'package-{flavor}-privacy.log')
    (LOG/f'package-{flavor}-binaries.json').write_text(json.dumps(entries,indent=2))
    return app

def package(flavor, arches, minimum, app):
    run(['python3',ROOT/'scripts/check-public-source.py','--app',app],log=f'package-{flavor}-privacy.log')
    assert (app/'Contents/Resources/OShell-LICENSE.txt').read_bytes()==(ROOT/'LICENSE').read_bytes(), 'Rebuild the app with the project license before packaging'

    suffix={'modern':'macOS13-Universal','arm64':'macOS13-arm64','legacy':'macOS10.13-Intel'}[flavor]
    base=f'OShell-{VERSION}-{suffix}'
    stage=WORK/flavor
    payload=stage/'payload'
    if payload.exists(): shutil.rmtree(payload)
    payload.mkdir()
    shutil.copytree(app,payload/'OShell.app',dirs_exist_ok=True,symlinks=True)
    component=stage/'component.plist'
    run(['pkgbuild','--analyze','--root',payload,component],log=f'package-{flavor}-analyze.log')
    components=plistlib.loads(component.read_bytes())
    for item in components:item['BundleIsRelocatable']=False;item['BundleIsVersionChecked']=False;item['BundleOverwriteAction']='upgrade'
    component.write_bytes(plistlib.dumps(components))
    part=stage/'OShell-component.pkg'
    run(['pkgbuild','--compression','legacy','--root',payload,'--component-plist',component,'--identifier','app.oshell.mac','--version',VERSION,'--install-location','/Applications',part],log=f'package-{flavor}-component.log')
    archlist=','.join(arches)
    distribution=stage/'Distribution.xml'
    distribution.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
<title>OShell {VERSION}</title>
<options customize="never" require-scripts="false" rootVolumeOnly="true" hostArchitectures="{archlist}"/>
<domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
<volume-check><allowed-os-versions><os-version min="{minimum}"/></allowed-os-versions></volume-check>
<choices-outline><line choice="default"/></choices-outline>
<choice id="default" title="OShell"><pkg-ref id="app.oshell.mac"/></choice>
<pkg-ref id="app.oshell.mac" version="{VERSION}" onConclusion="none">OShell-component.pkg</pkg-ref>
</installer-gui-script>
''')
    pkg=OUT/(base+'.pkg')
    run(['productbuild','--distribution',distribution,'--package-path',stage,pkg],log=f'package-{flavor}-product.log')
    image=stage/'image'
    if image.exists(): shutil.rmtree(image)
    image.mkdir()
    shutil.copytree(app,image/'OShell.app',dirs_exist_ok=True,symlinks=True)
    if not (image/'Applications').is_symlink():(image/'Applications').symlink_to('/Applications')
    (image/'安装说明.txt').write_text(f'OShell {VERSION}\n适用：macOS {minimum} 或更新版本；架构 {archlist}。\n把 OShell.app 拖入 Applications，或使用同版本 PKG 安装。\n新旧两种包使用同一个应用及会话目录，不需要同时安装。\n本包为本地 ad-hoc 签名，未进行 Developer ID 签名或 Apple 公证。\n旧包已完成编译和当前系统的 Intel 转译验证，尚未在真实 macOS 10.13 上验证。\n')
    dmg=OUT/(base+'.dmg')
    run(['hdiutil','create','-ov','-format','UDZO','-fs','HFS+','-volname',f'OShell {VERSION}','-srcfolder',image,dmg],log=f'package-{flavor}-dmg.log')
    run(['hdiutil','verify',dmg],log=f'package-{flavor}-dmg-verify.log')
    return [pkg,dmg]

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--flavor',choices=['modern','arm64','legacy','all'],default='all');parser.add_argument('--repository',help='Public GitHub owner/repo to embed as the default update source');parser.add_argument('--apps-only',action='store_true');parser.add_argument('--package-only',action='store_true');args=parser.parse_args()
    if args.repository:
        import re
        if not re.fullmatch(r'[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*/[A-Za-z0-9_.-]+',args.repository): parser.error('Repository must be owner/repo')
        INFO['OShellUpdateRepository']=args.repository
    WORK.mkdir(parents=True,exist_ok=True);OUT.mkdir(parents=True,exist_ok=True);LOG.mkdir(exist_ok=True)
    artifacts=[]
    for flavor,arches,minimum in [('modern',['arm64','x86_64'],'13.0'),('arm64',['arm64'],'13.0'),('legacy',['x86_64'],'10.13')]:
        if args.flavor not in ['all',flavor]:continue
        if args.package_only:
            app=WORK/flavor/'OShell.app'
            run(['codesign','--verify','--deep','--strict',app])
        else:
            binaries={a:build_swift(flavor,a,minimum) for a in arches}
            helpers={a:build_lrzsz(a,minimum) for a in arches}
            app=assemble(flavor,arches,minimum,binaries,helpers)
        print('Built application:',app,flush=True)
        if not args.apps_only:artifacts+=package(flavor,arches,minimum,app)
    if artifacts:
        checksum=OUT/'SHA256SUMS.txt'
        checksum.write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(OUT.glob('OShell-*')) if p.suffix in ['.pkg','.dmg']))
        for p in artifacts:print('Package:',p,flush=True)

if __name__=='__main__':main()
