#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Isolated native session-list layouts and existing management regressions."""
import json
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
for name, variable, output in [
    ('session-list', 'OSHELL_SESSION_LIST_ROOT', 'session-list-result.json'),
    ('management', 'OSHELL_MANAGEMENT_OUTPUT', 'session-list-management.json'),
    ('popup-keyboard', 'OSHELL_POPUP_OUTPUT', 'session-list-popup.json'),
    ('filetabs', 'OSHELL_FILETABS_OUTPUT', 'session-list-filetabs.json'),
]:
    with tempfile.TemporaryDirectory(prefix='oshell-session-list-', dir='/tmp') as directory:
        report_path = root / 'validation' / output
        report_path.unlink(missing_ok=True)
        env = dict(os.environ, OSHELL_DATA_DIR=directory)
        env[variable] = str(report_path.parent if name == 'session-list' else report_path)
        with (root / 'validation' / f'session-list-{name}.log').open('wb') as log:
            result = subprocess.run([str(root / 'dist/OShell.app/Contents/MacOS/OShell'), f'--{name}-test'], env=env, stdout=log, stderr=log, timeout=120)
        report = json.loads(report_path.read_text())
        failures = [key for key, passed in report['checks'].items() if not passed]
        print(name, 'checks:', len(report['checks']), 'passed:', report['passed'], 'failures:', failures, flush=True)
        if result.returncode or not report['passed']:
            raise SystemExit(1)
