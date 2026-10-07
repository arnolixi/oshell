#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""AppKit/terminal parser regressions, with no user connections or configuration."""
import json, os, pathlib, subprocess, tempfile
project=pathlib.Path(__file__).resolve().parent.parent
for name,variable in [('tab-behavior','OSHELL_TAB_BEHAVIOR_OUTPUT'),('layout','OSHELL_LAYOUT_OUTPUT')]:
    with tempfile.TemporaryDirectory(prefix='oshell-tab-regression-',dir='/tmp') as directory:
        output=project/'validation'/f'tab-update-{name}.json'
        env=os.environ.copy();env.update(OSHELL_DATA_DIR=directory);env[variable]=str(output)
        with (project/'validation'/f'tab-update-{name}.log').open('wb') as log:
            result=subprocess.run([str(project/'dist/OShell.app/Contents/MacOS/OShell'),f'--{name}-test'],env=env,stdout=log,stderr=log,timeout=90)
        report=json.loads(output.read_text());print(name,report['passed'],flush=True)
        if not report['passed'] or result.returncode:
            print(json.dumps(report,indent=2));raise SystemExit(1)
