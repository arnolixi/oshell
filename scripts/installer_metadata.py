# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Portable audit files inside a DMG, without modifying its signed application."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

AUDIT_FILES = {'release-manifest.json', 'SHA256SUMS.txt'}

def digest(path):
    with path.open('rb') as stream:
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): value.update(chunk)
    return value.hexdigest()

def inventory(root):
    files, links = [], {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root).as_posix()
        if relative in AUDIT_FILES: continue
        if path.is_symlink(): links[relative] = str(path.readlink())
        elif path.is_file(): files.append(relative)
    return files, links

def write(root, *, version, build, flavor, minimum, architectures, source_root):
    root = Path(root)
    info = plistlib.loads((root/'OShell.app/Contents/Info.plist').read_bytes())
    if (info['CFBundleShortVersionString'], str(info['CFBundleVersion']), info['LSMinimumSystemVersion']) != (version, str(build), minimum):
        raise ValueError('Rebuild application: installer version/build/deployment target does not match payload')
    commit = subprocess.run(['git', '-C', str(source_root), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    revision = commit.stdout.strip()
    status = subprocess.run(['git', '-C', str(source_root), 'status', '--porcelain', '--untracked-files=normal'], capture_output=True, text=True)
    files, links = inventory(root)
    manifest = dict(format='OShell.installer-payload.v1', version=version, build=str(build), flavor=flavor,
                    minimumOS=minimum, architectures=sorted(architectures), signing='ad-hoc', notarized=False,
                    commit=revision if re.fullmatch('[a-f0-9]{40,64}', revision) else None,
                    sourceDirty=bool(status.stdout) if status.returncode == 0 else None,
                    checksumScope='Files inside this DMG, including this manifest; excludes SHA256SUMS.txt itself and the outer DMG. Symlink targets are recorded separately.',
                    files=files, symlinks=links)
    (root/'release-manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False)+'\n')
    (root/'SHA256SUMS.txt').write_text(''.join(f'{digest(root/name)}  {name}\n' for name in sorted(files+['release-manifest.json'])))
    return manifest

def verify(root, *, version, build, flavor, minimum, architectures):
    root = Path(root)
    if any((root/name).is_symlink() for name in AUDIT_FILES): raise ValueError('Invalid installer audit file')
    manifest = json.loads((root/'release-manifest.json').read_text())
    expected = dict(format='OShell.installer-payload.v1', version=version, build=str(build), flavor=flavor, minimumOS=minimum, architectures=sorted(architectures))
    if any(manifest.get(key) != value for key, value in expected.items()): raise ValueError('Installer manifest does not match target')
    files, links = inventory(root)
    if manifest.get('files') != files or manifest.get('symlinks') != links: raise ValueError('Installer file inventory changed')
    allowed = set(files) | {'release-manifest.json'}; checked = set()
    for line in (root/'SHA256SUMS.txt').read_text().splitlines():
        checksum, name = line.split('  ', 1)
        if name not in allowed or name in checked or digest(root/name) != checksum: raise ValueError('Installer payload checksum mismatch')
        checked.add(name)
    if checked != allowed: raise ValueError('Incomplete installer payload checksums')
    return manifest
