#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Remove project-generated build history, keeping the current native release app."""
import argparse, hashlib, json, os, platform, plistlib, re, shutil, stat, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KEEP_REPORTS = {'.gitkeep', 'latest-build.log', 'latest-checks.json', 'latest-cleanup.json'}
BUILD_NAME = re.compile(r'build(?:-tests|-legacy|-compat-(?:arm64|x86_64)|-modern-(?:arm64|x86|x86_64)|-test-[a-z]+-(?:arm64|x86_64))?')
OLD_WORK = {
    'release','test-release','test-app','command-editor-modules','public-source-checkout',
    'brand-preview','deep-memory-baseline','memory-baseline','settings-preview','link-drag-native',
    'private-prepublish','privacy-audit','pages-bootstrap-preview','sparkle-inspect','fonts','touch-id',
    'update-repair','update-63-probe','update-63-probe.swift','update-63-release.json',
    'update-pages-probe','public-strip-check','command-editor-probe.swift','webdav-stall-sample.txt',
    'pages-live.json','release-0.2.65-pages.json','release-0.2.65-published.json',
    'AmbiguousWidthData.check.swift','EastAsianWidth-17.0.0.txt','Unicode-license.txt',
    'check-settings.py','check-session-fullscreen.py','run-external-import-checks.py',
    'run-link-bar-checks.py','run-quicksend-group-checks.py','run-shortcut-checks.py',
    'run-title-ui-checks.py','run-toolbar-checks.py','ci-output','ci-updates','release-input','update-input',
}

def candidates(root):
    paths = [root/'.build', root/'.swiftpm', root/'.DS_Store', root/'Assets/.DS_Store', root/'Assets/Brand/.DS_Store', root/'scripts/__pycache__', root/'work/ci-tools/gocache', root/'work/ci-tools/gomod']
    work = root/'work'
    if work.is_dir():
        paths += [p for p in work.iterdir() if p.name in OLD_WORK or BUILD_NAME.fullmatch(p.name)
                  or p.name.startswith(('ui-check-','settings-check-','release-diagnostics-'))]
    dist = root/'dist'
    if dist.is_dir(): paths += [p for p in dist.iterdir() if p.name != 'OShell.app']
    validation = root/'validation'
    if validation.is_dir(): paths += [p for p in validation.iterdir() if p.name not in KEEP_REPORTS]
    paths = {p for p in paths if p.exists() or p.is_symlink()}
    return sorted((p for p in paths if not any(parent in paths for parent in p.parents)), key=str)

def fingerprint(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob('*') if p.is_file() and not p.is_symlink()}

def validate_targets(root, paths, tracked, processes):
    keep = root/'dist/OShell.app'
    for p in paths:
        if not p.is_relative_to(root) or p == root or p == keep or keep.is_relative_to(p):
            raise RuntimeError('Unsafe cleanup target')
        relative = p.relative_to(root).as_posix()
        if any(f == relative or f.startswith(relative+'/') for f in tracked):
            raise RuntimeError('Cleanup would remove tracked files: '+relative)
        if any(exe == p or p in exe.parents for exe in processes):
            raise RuntimeError('A cleanup target is in use: '+relative)
        if not p.is_symlink() and not p.resolve().is_relative_to(root):
            raise RuntimeError('Cleanup target escapes the project')

def usage(root):
    paths = [str(root/name) for name in ('work','dist','validation') if (root/name).exists()]
    return sum(int(line.split()[0]) for line in subprocess.check_output(['du','-sk',*paths],text=True).splitlines())

def remove_directory(path):
    # Go/Swift download caches may use read-only directories. Add write access
    # only for our own directories; never follow links or change another owner.
    for folder, _, _ in os.walk(path, followlinks=False):
        directory = Path(folder); info = directory.lstat()
        if stat.S_ISLNK(info.st_mode): continue
        if info.st_uid != os.geteuid(): raise PermissionError('Cleanup directory has a different owner')
        directory.chmod(stat.S_IMODE(info.st_mode) | stat.S_IWUSR | stat.S_IXUSR)
    shutil.rmtree(path)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true',help='delete listed generated paths; default is a dry run')
    args = parser.parse_args(); root = ROOT.resolve(); paths = candidates(root)
    print(json.dumps({'remove':[p.relative_to(root).as_posix() for p in paths], 'keep':'dist/OShell.app'},indent=2))
    if not args.apply: return
    app = root/'dist/OShell.app'; info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('OShellTestHarness'): raise RuntimeError('Build the production app before cleanup')
    arches = subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS/OShell')],text=True).split()
    if arches != [platform.machine()]: raise RuntimeError('The retained app must match the native build host')
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    tracked = subprocess.check_output(['git','-C',str(root),'ls-files','-z'],text=True).split('\0')
    processes = [Path(parts[1]) for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines()
                 if len(parts := line.strip().split(None,1)) == 2]
    validate_targets(root, paths, tracked, processes)
    before = usage(root); original = fingerprint(app)
    status = subprocess.check_output(['git','-C',str(root),'status','--porcelain'],text=True)
    for p in paths:
        if p.is_symlink() or p.is_file(): p.unlink()
        else: remove_directory(p)
    if fingerprint(app) != original: raise RuntimeError('Retained application changed')
    if subprocess.check_output(['git','-C',str(root),'status','--porcelain'],text=True) != status:
        raise RuntimeError('Working tree status changed during cleanup')
    report = {'removed_roots':len(paths),'reclaimed_gib':round((before-usage(root))/1024/1024,2),
              'app':'dist/OShell.app','version':info['CFBundleShortVersionString'],'architecture':arches[0],'app_verified':True}
    (root/'validation/latest-cleanup.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__ == '__main__': main()
