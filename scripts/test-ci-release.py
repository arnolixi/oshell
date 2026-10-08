#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Offline checks: no GitHub mutations and no macOS toolchain required."""
import importlib.util
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from release_targets import TARGETS, RELEASE_FLAVORS

SCRIPTS = Path(__file__).resolve().parent

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS/filename)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

CI = module('ci_release', 'ci-release.py')
PACK = module('package_release', 'package-release.py')
META = dict(tag='v1.2.3', version='1.2.3', build='45', commit='a' * 40)

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='oshell-ci-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.incoming = self.root/'incoming'; self.incoming.mkdir()
        self.source = self.root/'OShell-1.2.3-source.tar.gz'; self.source.write_bytes(b'audited source fixture')
        self.output = self.root/'release'
        for flavor in RELEASE_FLAVORS:
            target = TARGETS[flavor]; folder = self.incoming/('dmg-' + flavor); folder.mkdir()
            name = CI.artifact_name(META['version'], flavor); dmg = folder/name; dmg.write_bytes(('fixture ' + flavor).encode())
            verification = dict(passed=True, version=META['version'], build=META['build'], dmg=name, dmgSHA256=CI.sha256(dmg), minimumOS=target.minimum, architectures=sorted(target.architectures), signaturesVerified=True, allMachOMinimumsVerified=True, payloadMatchesStagedApp=True)
            record = dict(META, flavor=flavor, file=name, sha256=CI.sha256(dmg), size=dmg.stat().st_size, verification=verification)
            (folder/'manifest.json').write_text(json.dumps(record))

    def collect(self):
        return CI.collect(META, self.incoming, self.source, self.output)

    def mutate(self, flavor, change):
        path = self.incoming/('dmg-' + flavor)/'manifest.json'; value = json.loads(path.read_text()); change(value); path.write_text(json.dumps(value))

    def test_four_distinct_target_names(self):
        self.assertEqual(len({CI.artifact_name('1.2.3', flavor) for flavor in RELEASE_FLAVORS}), 4)
        self.assertEqual(TARGETS['legacy'].architectures, ('x86_64',))
        self.assertEqual(TARGETS['compat'].architectures, ('arm64', 'x86_64'))
        self.assertEqual(TARGETS['compat'].minimum, '11.0')

    def test_stable_tag_must_match_version(self):
        CI.validate_tag('v1.2.3', '1.2.3')
        for tag in ['main', 'v1.2.4', 'v1.2.3-beta', 'v1.2.3\n', '../v1.2.3', 'v$(command)']:
            with self.assertRaises(ValueError): CI.validate_tag(tag, '1.2.3')

    def source_repository(self):
        repo = self.root/'repo'; repo.mkdir(); (repo/'scripts').mkdir()
        (repo/'scripts/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='1.2.3', CFBundleVersion='45')))
        def git(*args):
            return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL, text=True).strip()
        git('init'); git('config', 'user.name', 'Release Test'); git('config', 'user.email', 'release@example.test')
        git('add', '.'); git('commit', '-m', 'Release fixture')
        return repo, git

    def test_manual_first_release_infers_version_and_creates_tag(self):
        repo, git = self.source_repository(); head = git('rev-parse', 'HEAD'); calls = []
        def network(*args, check=True):
            calls.append(args)
            if len(calls) == 1: return subprocess.CompletedProcess(args, 1, '', 'HTTP 404')
            return subprocess.CompletedProcess(args, 0, json.dumps({'object': {'type': 'commit', 'sha': head}}), '')
        with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh', network):
            result = CI.prepare('', 'owner/repo')
        self.assertEqual(result['tag'], 'v1.2.3')
        self.assertEqual(git('rev-parse', 'refs/tags/v1.2.3'), head)
        self.assertIn('ref=refs/tags/v1.2.3', calls[1])
        self.assertIn('sha=' + head, calls[1])

    def test_manual_wrong_version_fails_before_network(self):
        repo, git = self.source_repository()
        with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh') as network:
            with self.assertRaisesRegex(ValueError, 'v1.2.3'):
                CI.prepare('v1.2.2', 'owner/repo')
            network.assert_not_called()
        self.assertEqual(git('tag'), '')

    def test_missing_tag_in_push_mode_has_actionable_error(self):
        repo, _ = self.source_repository()
        with patch.object(CI, 'ROOT', repo), self.assertRaisesRegex(ValueError, 'manually'):
            CI.metadata('v1.2.3')

    def test_manual_existing_tag_cannot_move(self):
        repo, git = self.source_repository(); git('tag', 'v1.2.3')
        git('commit', '--allow-empty', '-m', 'Later source')
        with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh') as network:
            with self.assertRaisesRegex(ValueError, 'never moved'):
                CI.prepare('', 'owner/repo')
            network.assert_not_called()

    def test_manual_existing_annotated_tag_is_reused(self):
        repo, git = self.source_repository(); head = git('rev-parse', 'HEAD')
        git('tag', '-a', 'v1.2.3', '-m', 'Release'); calls = []
        def network(*args, check=True):
            calls.append(args)
            ref = dict(type='commit', sha=head) if '/git/tags/' in args[1] else dict(type='tag', sha=git('rev-parse', 'v1.2.3'))
            return subprocess.CompletedProcess(args, 0, json.dumps(dict(object=ref)), '')
        with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh', network):
            self.assertEqual(CI.prepare('v1.2.3', 'owner/repo')['commit'], head)
        self.assertTrue(all('--method' not in call for call in calls))

    def test_manual_remote_tag_moved_or_api_denied_never_retargeted(self):
        repo, git = self.source_repository()
        for status, payload, error in [(0, json.dumps({'object': {'type': 'commit', 'sha': 'b' * 40}}), ''), (1, '', 'HTTP 403')]:
            with self.subTest(status=status), patch.object(CI, 'ROOT', repo):
                with patch.object(CI, 'gh', return_value=subprocess.CompletedProcess([], status, payload, error)) as network:
                    with self.assertRaises((ValueError, RuntimeError)): CI.prepare('', 'owner/repo')
                    self.assertTrue(all('--method' not in call.args for call in network.call_args_list))
            self.assertEqual(git('tag'), '')

    def test_manual_tag_creation_race_rechecks_remote_commit(self):
        for matching in [True, False]:
            with self.subTest(matching=matching):
                repo, git = self.source_repository(); head = git('rev-parse', 'HEAD')
                results = [subprocess.CompletedProcess([], 1, '', 'HTTP 404'),
                           subprocess.CompletedProcess([], 1, '', 'HTTP 422'),
                           subprocess.CompletedProcess([], 0, json.dumps({'object': {'type': 'commit', 'sha': head if matching else 'b' * 40}}), '')]
                with patch.object(CI, 'ROOT', repo), patch.object(CI, 'gh', side_effect=results):
                    if matching: self.assertEqual(CI.prepare('', 'owner/repo')['commit'], head)
                    else:
                        with self.assertRaises(ValueError): CI.prepare('', 'owner/repo')
                        self.assertEqual(git('tag'), '')
                import shutil
                shutil.rmtree(repo)

    def test_collect_complete_set_and_checksums(self):
        result = self.collect()
        self.assertEqual(len(result['installers']), 4)
        self.assertEqual(len(list(self.output.glob('*.dmg'))), 4)
        self.assertFalse(result['notarized'])
        for line in (self.output/'SHA256SUMS.txt').read_text().splitlines():
            expected, name = line.split('  ', 1); self.assertEqual(CI.sha256(self.output/name), expected)
        self.assertIn('ad-hoc', (self.output/'RELEASE_NOTES.md').read_text())

    def test_missing_build_prevents_release(self):
        import shutil
        shutil.rmtree(self.incoming/'dmg-intel')
        with self.assertRaises(ValueError): self.collect()
        self.assertFalse(self.output.exists())

    def test_wrong_source_commit_rejected(self):
        self.mutate('arm64', lambda record: record.update(commit='b' * 40))
        with self.assertRaises(ValueError): self.collect()

    def test_wrong_architecture_rejected(self):
        self.mutate('intel', lambda record: record['verification'].update(architectures=['arm64']))
        with self.assertRaises(ValueError): self.collect()

    def test_wrong_minimum_rejected(self):
        self.mutate('compat', lambda record: record['verification'].update(minimumOS='13.0'))
        with self.assertRaises(ValueError): self.collect()

    def test_unverified_payload_rejected(self):
        self.mutate('legacy', lambda record: record['verification'].update(payloadMatchesStagedApp=False))
        with self.assertRaises(ValueError): self.collect()

    def test_modified_dmg_rejected(self):
        next((self.incoming/'dmg-intel').glob('*.dmg')).write_bytes(b'tampered fixture')
        with self.assertRaises(ValueError): self.collect()

    def test_unexpected_files_rejected(self):
        (self.incoming/'dmg-arm64/unexpected.txt').write_text('not a release asset')
        with self.assertRaises(ValueError): self.collect()

    def test_stage_requires_verified_dmg(self):
        flavor = 'arm64'
        record = json.loads((self.incoming/'dmg-arm64/manifest.json').read_text())
        (self.root/'dist/installers').mkdir(parents=True)
        (self.root/'validation').mkdir()
        import shutil
        shutil.copy2(self.incoming/'dmg-arm64'/record['file'], self.root/'dist/installers'/record['file'])
        report = self.root/'validation/package-installers-verification.json'
        report.write_text(json.dumps(dict(passed=True, packages=[record['verification']])))
        # A report must explicitly identify its flavor, not just pass globally.
        with patch.object(CI, 'ROOT', self.root), self.assertRaises(ValueError):
            CI.stage(META, flavor, self.root/'staged')
        record['verification']['flavor'] = flavor
        report.write_text(json.dumps(dict(passed=True, packages=[record['verification']])))
        with patch.object(CI, 'ROOT', self.root): CI.stage(META, flavor, self.root/'staged')
        staged = json.loads((self.root/'staged/manifest.json').read_text())
        self.assertEqual(staged['commit'], META['commit'])
        self.assertEqual(staged['sha256'], record['sha256'])

    def test_empty_checksum_list_prevents_publish(self):
        self.collect(); (self.output/'SHA256SUMS.txt').write_text('')
        with patch.object(CI, 'gh') as network, self.assertRaises(ValueError):
            CI.publish(META, 'owner/repo', self.output)
        network.assert_not_called()

    def fake_gh(self, calls, existing=None, fail_upload=False, incomplete=False, moved=False):
        def invoke(*args, check=True):
            calls.append(args)
            output, error, status = '', '', 0
            if args[0] == 'api':
                output = json.dumps({'object': {'type': 'commit', 'sha': 'b' * 40 if moved else META['commit']}})
            elif args[:2] == ('release', 'view'):
                if args[-1] == 'isDraft,body':
                    if existing is None: status, error = 1, 'release not found'
                    else: output = json.dumps(existing)
                elif args[-1] == 'assets':
                    assets = [dict(name=path.name, size=path.stat().st_size) for path in self.output.iterdir() if path.name != 'RELEASE_NOTES.md']
                    output = json.dumps({'assets': assets[:-1] if incomplete else assets})
            elif args[:2] == ('release', 'upload') and fail_upload:
                raise subprocess.CalledProcessError(1, ['gh', *args])
            return subprocess.CompletedProcess(['gh', *args], status, output, error)
        return invoke

    def test_publication_is_draft_upload_verify_publish(self):
        self.collect(); calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls)):
            CI.publish(META, 'owner/repo', self.output)
        steps = [call[:2] for call in calls]
        self.assertLess(steps.index(('release', 'create')), steps.index(('release', 'upload')))
        self.assertEqual(steps[-1], ('release', 'edit'))
        self.assertIn('--draft', next(call for call in calls if call[:2] == ('release', 'create')))
        self.assertIn('--draft=false', calls[-1])

    def test_upload_failure_leaves_draft(self):
        self.collect(); calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls, fail_upload=True)), self.assertRaises(subprocess.CalledProcessError):
            CI.publish(META, 'owner/repo', self.output)
        self.assertFalse(any(call[:2] == ('release', 'edit') for call in calls))

    def test_incomplete_remote_assets_never_published(self):
        self.collect(); calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls, incomplete=True)), self.assertRaises(ValueError):
            CI.publish(META, 'owner/repo', self.output)
        self.assertFalse(any(call[:2] == ('release', 'edit') for call in calls))

    def test_published_release_is_immutable(self):
        self.collect(); calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls, existing=dict(isDraft=False, body=''))), self.assertRaises(ValueError):
            CI.publish(META, 'owner/repo', self.output)
        self.assertFalse(any(call[:2] == ('release', 'upload') for call in calls))

    def test_retry_only_resumes_own_draft(self):
        self.collect(); calls = []
        owned = dict(isDraft=True, body='<!-- oshell-release:' + META['commit'] + ' -->')
        with patch.object(CI, 'gh', self.fake_gh(calls, existing=owned)):
            CI.publish(META, 'owner/repo', self.output)
        self.assertFalse(any(call[:2] == ('release', 'create') for call in calls))
        with patch.object(CI, 'gh', self.fake_gh([], existing=dict(isDraft=True, body='manual draft'))), self.assertRaises(ValueError):
            CI.publish(META, 'owner/repo', self.output)

    def test_moved_tag_prevents_any_release_write(self):
        self.collect(); calls = []
        with patch.object(CI, 'gh', self.fake_gh(calls, moved=True)), self.assertRaises(ValueError):
            CI.publish(META, 'owner/repo', self.output)
        self.assertEqual(len(calls), 1)

    def test_dmg_only_skips_pkg_tools(self):
        root = self.root/'package'; root.mkdir(); (root/'LICENSE').write_text('license fixture')
        app = root/'app/OShell.app'; resources = app/'Contents/Resources'; resources.mkdir(parents=True)
        (resources/'OShell-LICENSE.txt').write_text('license fixture')
        work, out = root/'work', root/'out'; (work/'arm64').mkdir(parents=True); out.mkdir()
        calls = []
        def fake_run(args, **kwargs):
            calls.append(args)
            if args[:2] == ['hdiutil', 'create']: Path(args[-1]).write_bytes(b'fake DMG')
        with patch.multiple(PACK, ROOT=root, WORK=work, OUT=out), patch.object(PACK, 'run', fake_run):
            artifacts = PACK.package('arm64', ['arm64'], '13.0', app, 'dmg')
        self.assertEqual([path.suffix for path in artifacts], ['.dmg'])
        self.assertFalse(any(call[0] in ['pkgbuild', 'productbuild'] for call in calls))
        self.assertTrue(any(call[:2] == ['hdiutil', 'verify'] for call in calls))

if __name__ == '__main__':
    unittest.main()
