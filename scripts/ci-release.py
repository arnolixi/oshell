#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Validate tag builds, collect four verified DMGs, and publish a complete Release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
from release_targets import TARGETS, RELEASE_FLAVORS

ROOT = Path(__file__).resolve().parent.parent

def sha256(path):
    with path.open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()

def validate_tag(tag, version):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag) or tag != 'v' + version:
        raise ValueError('Use a stable vX.Y.Z tag matching scripts/Info.plist CFBundleShortVersionString')

def metadata(tag, commit=None):
    info = plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], str(info['CFBundleVersion'])
    validate_tag(tag, version)
    if not build.isdigit() or int(build) < 1:
        raise ValueError('CFBundleVersion must be a positive, increasing integer')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()
    head = git('rev-parse', 'HEAD')
    if git('rev-parse', '--verify', 'refs/tags/' + tag + '^{commit}') != head or (commit and commit != head):
        raise ValueError('Release tag, checked-out source and requested commit must match')
    return dict(tag=tag, version=version, build=build, commit=head)

def artifact_name(version, flavor):
    return f'OShell-{version}-{TARGETS[flavor].suffix}.dmg'

def stage(meta, flavor, output):
    target = TARGETS[flavor]
    name = artifact_name(meta['version'], flavor)
    dmg = ROOT/'dist/installers'/name
    report = json.loads((ROOT/'validation/package-installers-verification.json').read_text())
    entries = [value for value in report.get('packages', []) if value.get('flavor') == flavor]
    if not report.get('passed') or len(entries) != 1:
        raise ValueError('Missing successful installer verification for ' + flavor)
    entry = entries[0]
    expected = dict(version=meta['version'], build=meta['build'], minimumOS=target.minimum, architectures=sorted(target.architectures), dmg=name)
    if any(entry.get(key) != value for key, value in expected.items()) or not all(entry.get(key) for key in ['passed', 'signaturesVerified', 'allMachOMinimumsVerified', 'payloadMatchesStagedApp']):
        raise ValueError('Stale or incomplete package verification for ' + flavor)
    if entry.get('dmgSHA256') != sha256(dmg):
        raise ValueError('DMG changed after validation')
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Artifact output must be empty')
    shutil.copy2(dmg, output/name)
    manifest = dict(meta, flavor=flavor, file=name, sha256=sha256(dmg), size=dmg.stat().st_size, verification=entry)
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

def collect(meta, artifacts, source, output):
    expected_dirs = {'dmg-' + flavor for flavor in RELEASE_FLAVORS}
    if {path.name for path in artifacts.iterdir()} != expected_dirs:
        raise ValueError('Exactly four build artifacts are required; missing or unexpected artifacts found')
    records = []
    for flavor in RELEASE_FLAVORS:
        folder = artifacts/('dmg-' + flavor)
        record = json.loads((folder/'manifest.json').read_text())
        name = artifact_name(meta['version'], flavor)
        target = TARGETS[flavor]
        verification = record.get('verification', {})
        if any(record.get(key) != value for key, value in meta.items()) or record.get('flavor') != flavor or record.get('file') != name:
            raise ValueError('Mixed versions/commits in build artifacts')
        if any(verification.get(key) != value for key, value in dict(minimumOS=target.minimum, architectures=sorted(target.architectures), version=meta['version'], build=meta['build'], dmg=name).items()):
            raise ValueError('Unexpected platform verification')
        if not all(verification.get(key) for key in ['passed', 'signaturesVerified', 'allMachOMinimumsVerified', 'payloadMatchesStagedApp']):
            raise ValueError('Unverified installer')
        dmg = folder/name
        if dmg.is_symlink() or sha256(dmg) != record.get('sha256') or dmg.stat().st_size != record.get('size') or verification.get('dmgSHA256') != record.get('sha256'):
            raise ValueError('Artifact integrity check failed for ' + flavor)
        if {path.name for path in folder.iterdir()} != {name, 'manifest.json'}:
            raise ValueError('Unexpected files in artifact')
        records.append(record)
    if source.name != f"OShell-{meta['version']}-source.tar.gz" or not source.is_file() or source.is_symlink():
        raise ValueError('Expected the audited source archive for this version')
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Release output must be empty')
    for record in records:
        shutil.copy2(artifacts/('dmg-' + record['flavor'])/record['file'], output/record['file'])
    shutil.copy2(source, output/source.name)
    release_manifest = dict(meta, signing='ad-hoc', notarized=False, installers=records,
                            source=dict(file=source.name, sha256=sha256(source)))
    (output/'release-manifest.json').write_text(json.dumps(release_manifest, indent=2) + '\n')
    assets = sorted(output.iterdir())
    (output/'SHA256SUMS.txt').write_text(''.join(f'{sha256(path)}  {path.name}\n' for path in assets))
    rows = '\n'.join(f"| {TARGETS[flavor].minimum}+ | {', '.join(TARGETS[flavor].architectures)} | `{artifact_name(meta['version'], flavor)}` |" for flavor in RELEASE_FLAVORS)
    notes = f"""<!-- oshell-release:{meta['commit']} -->
OShell {meta['version']}（build {meta['build']}）

| 最低 macOS | 架构 | DMG |
| --- | --- | --- |
{rows}

现代版以 macOS 13 为最低目标，也适用于更新系统；Universal 同时包含 Intel 与 Apple Silicon。
下载适合本机的一种 DMG，将 OShell.app 拖入 Applications。SHA256SUMS.txt 提供校验值，对应源码包随附。

这些安装包使用 ad-hoc 签名，未进行 Developer ID 签名或 Apple 公证。流水线校验架构、部署目标、载荷和签名完整性，并运行构建机原生架构的核心测试；不代表已在 macOS 10.13/11 的真实系统上完成验证。
本次流水线仅发布手动安装包，不生成 Sparkle 签名更新清单。

对应提交：`{meta['commit']}`
"""
    (output/'RELEASE_NOTES.md').write_text(notes)
    return release_manifest

def gh(*args, check=True):
    return subprocess.run(['gh', *args], capture_output=True, text=True, check=check)

def verify_remote_tag(repository, tag, commit):
    ref = json.loads(gh('api', f'repos/{repository}/git/ref/tags/{tag}').stdout)['object']
    for _ in range(8):
        if ref['type'] == 'commit':
            if ref['sha'] != commit: raise ValueError('Remote tag moved after builds started')
            return
        if ref['type'] != 'tag': break
        ref = json.loads(gh('api', f"repos/{repository}/git/tags/{ref['sha']}").stdout)['object']
    raise ValueError('Cannot resolve release tag to its source commit')

def publish(meta, repository, output):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Repository must be owner/repo')
    files = sorted(path for path in output.iterdir() if path.name != 'RELEASE_NOTES.md')
    expected = {artifact_name(meta['version'], flavor) for flavor in RELEASE_FLAVORS} | {f"OShell-{meta['version']}-source.tar.gz", 'release-manifest.json', 'SHA256SUMS.txt'}
    if {path.name for path in files} != expected:
        raise ValueError('Release asset set is incomplete')
    checked = set()
    for line in (output/'SHA256SUMS.txt').read_text().splitlines():
        digest, name = line.split('  ', 1)
        if Path(name).name != name or name not in expected or name in checked or (output/name).is_symlink() or sha256(output/name) != digest:
            raise ValueError('Release checksum verification failed')
        checked.add(name)
    if checked != expected - {'SHA256SUMS.txt'}:
        raise ValueError('Release checksums do not cover every asset')
    verify_remote_tag(repository, meta['tag'], meta['commit'])
    existing = gh('release', 'view', meta['tag'], '--repo', repository, '--json', 'isDraft,body', check=False)
    marker = '<!-- oshell-release:' + meta['commit'] + ' -->'
    if existing.returncode == 0:
        value = json.loads(existing.stdout)
        if not value['isDraft'] or marker not in value.get('body', ''):
            raise ValueError('Refusing to modify a published Release or a draft not created for this commit')
    elif 'release not found' in existing.stderr.lower() or 'HTTP 404' in existing.stderr:
        gh('release', 'create', meta['tag'], '--repo', repository, '--verify-tag', '--target', meta['commit'], '--draft', '--title', 'OShell ' + meta['version'], '--notes-file', str(output/'RELEASE_NOTES.md'))
    else:
        raise RuntimeError(existing.stderr)
    # --clobber is used only for an unpublished draft owned by this workflow/commit.
    gh('release', 'upload', meta['tag'], *map(str, files), '--repo', repository, '--clobber')
    assets = json.loads(gh('release', 'view', meta['tag'], '--repo', repository, '--json', 'assets').stdout)['assets']
    remote = {asset['name']: asset['size'] for asset in assets}
    if remote != {path.name: path.stat().st_size for path in files}:
        raise ValueError('Incomplete remote assets; Release remains a draft')
    verify_remote_tag(repository, meta['tag'], meta['commit'])
    gh('release', 'edit', meta['tag'], '--repo', repository, '--draft=false', '--latest')
    print('Published', meta['tag'], 'with four verified DMGs and corresponding source')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['metadata', 'stage', 'collect', 'publish'])
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit')
    parser.add_argument('--github-output', type=Path)
    parser.add_argument('--flavor', choices=RELEASE_FLAVORS)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--artifacts', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY', ''))
    args = parser.parse_args()
    meta = metadata(args.tag, args.commit)
    if args.command == 'metadata':
        if args.github_output:
            with args.github_output.open('a') as stream:
                stream.write(''.join(f'{key}={value}\n' for key, value in meta.items()))
        print(json.dumps(meta, indent=2))
    elif args.command == 'stage':
        if not args.flavor or not args.output: parser.error('stage needs --flavor and --output')
        stage(meta, args.flavor, args.output)
    elif args.command == 'collect':
        if not args.artifacts or not args.source or not args.output: parser.error('collect needs --artifacts, --source and --output')
        collect(meta, args.artifacts, args.source, args.output)
    else:
        if not args.output or not args.repository: parser.error('publish needs --output and --repository')
        publish(meta, args.repository, args.output)

if __name__ == '__main__':
    main()
