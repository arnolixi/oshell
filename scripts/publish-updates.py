#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Prepare signed GitHub Release assets locally. Never creates/uploads a release."""
import argparse,base64,hashlib,importlib.util,json,pathlib,plistlib,re,subprocess,xml.etree.ElementTree as ET
ROOT=pathlib.Path(__file__).resolve().parent.parent
SPEC=importlib.util.spec_from_file_location('signing_key',ROOT/'scripts/update-signing-key.py');KEYS=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(KEYS)
SIGN=ROOT/'Vendor/Sparkle/bin/sign_update'
NAMESPACE='http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle',NAMESPACE)
def run(args): return subprocess.check_output([str(x) for x in args],text=True).strip()
def repository(value):
    value=value.removeprefix('https://github.com/').strip('/')
    if value.endswith('.git'): value=value[:-4]
    if not re.fullmatch(r'[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*/[A-Za-z0-9_.-]+',value) or value.split('/')[-1] in ['.','..']: raise ValueError('Use owner/repo or its GitHub HTTPS URL')
    return value

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository',required=True,type=repository)
    parser.add_argument('--tag',required=True)
    parser.add_argument('--private-key',type=pathlib.Path,default=KEYS.PRIVATE)
    parser.add_argument('--flavor',action='append',choices=['arm64','legacy'])
    parser.add_argument('--output',type=pathlib.Path)
    parser.add_argument('--notes',type=pathlib.Path)
    args=parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+',args.tag) or args.tag in ['.','..']: parser.error('Use a plain tag such as v0.2.42')
    info=plistlib.loads((ROOT/'scripts/Info.plist').read_bytes()); version=info['CFBundleShortVersionString']; build=info['CFBundleVersion']
    if args.private_key.is_symlink() or args.private_key.stat().st_mode & 0o077: parser.error('Signing key permissions must be 0600')
    if KEYS.public_key(args.private_key)!=info['SUPublicEDKey']: parser.error('Private key does not match the public key embedded in the app')
    out=args.output or ROOT/'dist/updates'/version;out.mkdir(parents=True,exist_ok=True)
    flavors=args.flavor or ['arm64','legacy'];artifacts=[]
    for flavor in flavors:
        suffix,minimum=('macOS13-arm64','13.0') if flavor=='arm64' else ('macOS10.13-Intel','10.13')
        app=ROOT/'work/release'/flavor/'OShell.app';actual=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        for key in ['CFBundleShortVersionString','CFBundleVersion','SUPublicEDKey']: assert actual.get(key)==info[key],f'{flavor}: rebuild app; stale {key}'
        assert actual.get('LSMinimumSystemVersion')==minimum
        assert actual.get('OShellUpdateRepository','') in ['',args.repository]
        run(['codesign','--verify','--deep','--strict',app])
        run(['python3',ROOT/'scripts/check-public-source.py','--app',app])
        assert (app/'Contents/Resources/OShell-LICENSE.txt').read_bytes()==(ROOT/'LICENSE').read_bytes()
        archive=out/f'OShell-{version}-{suffix}-update.zip'
        # Do not mutate published archives under an existing version/tag.
        if archive.exists(): raise SystemExit(f'Output already exists: {archive}; choose a clean output directory')
        run(['ditto','-c','-k','--keepParent',app,archive])
        signature=run([SIGN,'--ed-key-file',args.private_key,'-p',archive])
        run([SIGN,'--ed-key-file',args.private_key,'--verify',archive,signature])
        feed=out/f'OShell-{suffix}.xml'
        rss=ET.Element('rss',{'version':'2.0'});channel=ET.SubElement(rss,'channel')
        ET.SubElement(channel,'title').text=f'OShell {suffix}'
        item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text=f'OShell {version}'
        ET.SubElement(item,f'{{{NAMESPACE}}}version').text=build
        ET.SubElement(item,f'{{{NAMESPACE}}}shortVersionString').text=version
        ET.SubElement(item,f'{{{NAMESPACE}}}minimumSystemVersion').text=minimum
        if flavor=='arm64': ET.SubElement(item,f'{{{NAMESPACE}}}hardwareRequirements').text='arm64'
        if args.notes: ET.SubElement(item,'description').text=args.notes.read_text()
        ET.SubElement(item,'enclosure',{'url':f'https://github.com/{args.repository}/releases/download/{args.tag}/{archive.name}',f'{{{NAMESPACE}}}edSignature':signature,'length':str(archive.stat().st_size),'type':'application/octet-stream'})
        ET.ElementTree(rss).write(feed,encoding='utf-8',xml_declaration=True)
        run([SIGN,'--ed-key-file',args.private_key,'-p',feed]);run([SIGN,'--ed-key-file',args.private_key,'--verify',feed])
        artifacts.extend([archive,feed])
    (out/'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in artifacts))
    (out/'release-assets.json').write_text(json.dumps({'version':version,'build':build,'repository':args.repository,'tag':args.tag,'assets':[p.name for p in artifacts],'published':False},indent=2))
    print(f'Prepared {len(artifacts)} signed assets in {out}. Upload both architectures and both XML feeds to the same latest stable GitHub Release. Nothing uploaded.')
if __name__=='__main__':main()
