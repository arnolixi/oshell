#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Isolated UI/PTY regressions for terminal storage and idle cleanup."""
import json, os, pathlib, subprocess, tempfile
project=pathlib.Path(__file__).resolve().parent.parent
cases=[('idle-memory','OSHELL_IDLE_MEMORY_OUTPUT'),('layout','OSHELL_LAYOUT_OUTPUT'),('ended-broadcast','OSHELL_ENDED_BROADCAST_OUTPUT'),('stress','OSHELL_STRESS_OUTPUT')]
for name,variable in cases:
    with tempfile.TemporaryDirectory(prefix='oshell-memory-regression-',dir='/tmp') as folder:
        output=project/'validation'/f'memory-cycles-{name}.json'
        env=os.environ.copy();env.update(OSHELL_DATA_DIR=folder);env[variable]=str(output)
        with (project/'validation'/f'memory-cycles-{name}.log').open('wb') as log:
            result=subprocess.run([str(project/'dist/OShell.app/Contents/MacOS/OShell'),f'--{name}-test'],env=env,stdout=log,stderr=log,timeout=90)
        data=json.loads(output.read_text())
        print(name, 'exit',result.returncode,'passed',data.get('passed', 'see timings'), flush=True)
        if result.returncode != 0 or data.get('passed') is False: raise SystemExit(1)
