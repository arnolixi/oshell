#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Portable signing policy checks; never imports a real private key."""
import base64, json, os, pathlib, tempfile, unittest
from unittest.mock import patch
import code_signing as signing

class SigningTests(unittest.TestCase):
    def test_requirement_pins_certificate_and_identifier(self):
        value = signing.requirement('app.oshell.mac','a'*40)
        self.assertIn('identifier "app.oshell.mac"',value); self.assertIn('certificate leaf = H"'+'a'*40+'"',value)
        self.assertNotIn('cdhash',value); self.assertNotIn('anchor trusted',value)
    def test_requirement_rejects_injection(self):
        for identifier,pin in [('app.oshell" or true','a'*40),('app.oshell','bad')]:
            with self.assertRaises(ValueError): signing.requirement(identifier,pin)
    def test_public_pin_is_valid(self):
        pin = signing.profile(); self.assertEqual(len(pin['sha256']),64)
    def test_no_silent_credential_fallback(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(signing,'PRIVATE',pathlib.Path(folder)), patch.dict(os.environ,{},clear=True):
            with self.assertRaisesRegex(ValueError,'credentials missing'), signing.identity(): pass
    def test_partial_environment_fails(self):
        with patch.dict(os.environ,{'OSHELL_CODESIGN_P12':'eA=='},clear=True):
            with self.assertRaises(ValueError), signing.identity(): pass
    def test_wrong_certificate_rejected_before_keychain_creation(self):
        with patch.dict(os.environ,{'OSHELL_CODESIGN_P12':base64.b64encode(b'fixture').decode(),'OSHELL_CODESIGN_PASSWORD':'fixture-password'},clear=True), patch.object(signing,'run',side_effect=[b'public cert',b'wrong cert']) as run:
            with self.assertRaisesRegex(ValueError,'does not match'), signing.identity(): pass
            self.assertFalse(any(call.args[0][0]=='security' for call in run.call_args_list))
    def test_metadata_labels_are_truthful(self):
        self.assertEqual(signing.metadata({})['signing'],'ad-hoc')
        self.assertEqual(signing.metadata({signing.MARKER:'a'*64})['signing'],'self-signed')
    def test_init_refuses_rotation(self):
        import importlib.util
        spec=importlib.util.spec_from_file_location('init_signing',signing.ROOT/'scripts/init-code-signing.py'); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        # Initialization must refuse replacement before requiring cryptography.
        with self.assertRaisesRegex(RuntimeError,'already exists'): module.initialize()
    def test_official_build_rejects_adhoc(self):
        import plistlib
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ,{'OSHELL_ALLOW_ADHOC':'1','OSHELL_REQUIRE_FIXED_SIGNING':'1'},clear=True):
            app=pathlib.Path(folder)/'OShell.app'; (app/'Contents').mkdir(parents=True)
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.oshell.mac'}))
            with self.assertRaisesRegex(ValueError,'Official builds'): signing.sign_app(app)

if __name__=='__main__': unittest.main()
