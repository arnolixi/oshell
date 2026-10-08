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
import xml.etree.ElementTree as ET
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
        raise ValueError(f'Release tag {tag!r} must match scripts/Info.plist: v{version}. For a manual run, leave tag empty to use this version.')

def metadata(tag, commit=None, allow_missing_tag=False):
    info = plistlib.loads((ROOT/'scripts/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], str(info['CFBundleVersion'])
    if allow_missing_tag and not tag: tag = 'v' + version
    validate_tag(tag, version)
    if not build.isdigit() or int(build) < 1:
        raise ValueError('CFBundleVersion must be a positive, increasing integer')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()
    head = git('rev-parse', 'HEAD')
    ref = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--verify', '--quiet', 'refs/tags/' + tag + '^{commit}'], capture_output=True, text=True)
    if ref.returncode and not allow_missing_tag:
        raise ValueError(f'Release tag {tag} does not exist. Run the workflow manually from the source branch to create it.')
    if (not ref.returncode and ref.stdout.strip() != head) or (commit and commit != head):
        raise ValueError('Release tag, selected branch/tag and requested commit must match; existing tags are never moved. Select the original tag to retry, or increment the version for a new release.')
    return dict(tag=tag, version=version, build=build, commit=head)

def prepare(tag, repository):
    """Manual runs pin the selected source commit, including first-time releases."""
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Repository must be owner/repo')
    meta = metadata(tag, allow_missing_tag=True)
    endpoint = f"repos/{repository}/git/ref/tags/{meta['tag']}"
    existing = gh('api', endpoint, check=False)
    if existing.returncode:
        if 'HTTP 404' not in existing.stderr: raise RuntimeError(existing.stderr)
        # POST only: never patch/force-update an existing ref, including races.
        created = gh('api', f'repos/{repository}/git/refs', '--method', 'POST',
                     '-f', 'ref=refs/tags/' + meta['tag'], '-f', 'sha=' + meta['commit'], check=False)
        if created.returncode and 'HTTP 422' not in created.stderr: raise RuntimeError(created.stderr)
    verify_remote_tag(repository, meta['tag'], meta['commit'])
    # Downstream metadata validation also requires a local immutable tag.
    ref = subprocess.run(['git', '-C', str(ROOT), 'show-ref', '--verify', '--quiet', 'refs/tags/' + meta['tag']])
    if ref.returncode:
        subprocess.run(['git', '-C', str(ROOT), 'tag', meta['tag'], meta['commit']], check=True)
    return metadata(meta['tag'], meta['commit'])

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

def update_asset_names(version):
    return {name for flavor in ['arm64', 'legacy'] for name in [
        f'OShell-{version}-{TARGETS[flavor].suffix}-update.zip', f'OShell-{TARGETS[flavor].suffix}.xml']}

def collect_updates(meta, artifacts, repository):
    if {path.name for path in artifacts.iterdir()} != {'updates-arm64', 'updates-legacy'}:
        raise ValueError('Both signed update architectures are required')
    assets = []
    sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    for flavor in ['arm64', 'legacy']:
        folder = artifacts/('updates-' + flavor)
        suffix = TARGETS[flavor].suffix
        names = {f"OShell-{meta['version']}-{suffix}-update.zip", f'OShell-{suffix}.xml'}
        manifest = json.loads((folder/'release-assets.json').read_text())
        if any(manifest.get(key) != value for key, value in dict(version=meta['version'], build=meta['build'], tag=meta['tag'], repository=repository).items()) or set(manifest.get('assets', [])) != names:
            raise ValueError('Update assets do not match this release')
        if {p.name for p in folder.iterdir()} != names | {'release-assets.json', 'SHA256SUMS.txt'}:
            raise ValueError('Unexpected update artifact files')
        checksums = {}
        for line in (folder/'SHA256SUMS.txt').read_text().splitlines():
            digest, name = line.split('  ', 1)
            if name not in names or name in checksums: raise ValueError('Invalid update checksum list')
            checksums[name] = digest
        if set(checksums) != names: raise ValueError('Missing update checksums')
        for name in sorted(names):
            path = folder/name
            if path.is_symlink() or sha256(path) != checksums[name]: raise ValueError('Update artifact integrity check failed')
            assets.append(path)
        item = ET.parse(folder/f'OShell-{suffix}.xml').find('./channel/item')
        if item is None or item.findtext(sparkle+'version') != meta['build'] or item.findtext(sparkle+'shortVersionString') != meta['version'] or item.findtext(sparkle+'minimumSystemVersion') != TARGETS[flavor].minimum:
            raise ValueError('Update feed version or deployment target mismatch')
        enclosure = item.find('enclosure'); archive = folder/f"OShell-{meta['version']}-{suffix}-update.zip"
        if enclosure is None or enclosure.get('url') != f"https://github.com/{repository}/releases/download/{meta['tag']}/{archive.name}" or enclosure.get('length') != str(archive.stat().st_size) or not enclosure.get(sparkle+'edSignature'):
            raise ValueError('Update feed has no valid matching signed enclosure')
    return assets

def collect(meta, artifacts, source, output, updates_artifacts=None, repository=""):
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
    updates = collect_updates(meta, updates_artifacts, repository) if updates_artifacts else []
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Release output must be empty')
    for record in records:
        shutil.copy2(artifacts/('dmg-' + record['flavor'])/record['file'], output/record['file'])
    shutil.copy2(source, output/source.name)
    release_manifest = dict(meta, signing='ad-hoc', notarized=False, installers=records,
                            source=dict(file=source.name, sha256=sha256(source)))
    for path in updates: shutil.copy2(path, output/path.name)
    if updates: release_manifest['updateAssets'] = [dict(file=p.name, sha256=sha256(p)) for p in updates]
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
{'包含两个架构的签名 ZIP 与 XML 清单，可用于 OShell 内置更新。' if updates else '本次仅发布手动安装包，不包含内置更新文件。'}

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
    manifest = json.loads((output/'release-manifest.json').read_text())
    if manifest.get('updateAssets'):
        names = {record['file'] for record in manifest['updateAssets']}
        if names != update_asset_names(meta['version']): raise ValueError('Both update flavors must be published together')
        expected |= names
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
    parser.add_argument('command', choices=['prepare', 'metadata', 'stage', 'collect', 'publish'])
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit')
    parser.add_argument('--build-only', action='store_true', help='Validate untagged source for metadata/stage without creating a release')
    parser.add_argument('--github-output', type=Path)
    parser.add_argument('--flavor', choices=RELEASE_FLAVORS)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--artifacts', type=Path)
    parser.add_argument('--updates-artifacts', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY', ''))
    args = parser.parse_args()
    if args.build_only and args.command not in ['metadata', 'stage']: parser.error('--build-only is only valid for metadata/stage')
    meta = prepare(args.tag, args.repository) if args.command == 'prepare' else metadata(args.tag, args.commit, allow_missing_tag=args.build_only)
    if args.command in ['prepare', 'metadata']:
        if args.github_output:
            with args.github_output.open('a') as stream:
                stream.write(''.join(f'{key}={value}\n' for key, value in meta.items()))
        print(json.dumps(meta, indent=2))
    elif args.command == 'stage':
        if not args.flavor or not args.output: parser.error('stage needs --flavor and --output')
        stage(meta, args.flavor, args.output)
    elif args.command == 'collect':
        if not args.artifacts or not args.source or not args.output: parser.error('collect needs --artifacts, --source and --output')
        collect(meta, args.artifacts, args.source, args.output, args.updates_artifacts, args.repository)
    else:
        if not args.output or not args.repository: parser.error('publish needs --output and --repository')
        publish(meta, args.repository, args.output)

if __name__ == '__main__':
    main()
