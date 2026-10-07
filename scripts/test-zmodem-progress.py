#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Real local terminal transfers, throttled enough to observe intermediate progress."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='oshell-progress-', dir='/tmp') as temporary:
    root = Path(temporary)
    helpers = root / 'helpers'; helpers.mkdir()
    app_bundle = Path(os.environ.get('OSHELL_TEST_APP', str(project/'dist/OShell.app')))
    real = app_bundle/'Contents/Helpers'
    for name in ['lrz', 'OShellAskpass', 'OShellProxy']:
        (helpers / name).symlink_to(real / name)
    wrapper = helpers / 'lsz'
    wrapper.write_text('#!' + sys.executable + '\n' + """import os, signal, subprocess, sys, time
# Leave the helper's protocol/TTY descriptors untouched. Briefly pause only
# this owned child so native AppKit can observe intermediate progress.
p = subprocess.Popen([os.environ['OSHELL_REAL_LSZ'], *sys.argv[1:]])
def stop(*_):
    if p.poll() is None:
        try: os.kill(p.pid, signal.SIGCONT)
        except ProcessLookupError: pass
        p.terminate()
        try: p.wait(timeout=2)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    sys.exit(143)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while p.poll() is None:
    try: os.kill(p.pid, signal.SIGSTOP)
    except ProcessLookupError: break
    time.sleep(.04)
    try: os.kill(p.pid, signal.SIGCONT)
    except ProcessLookupError: break
    time.sleep(.002)
sys.exit(p.wait())
""")
    wrapper.chmod(0o700)
    env = dict(os.environ, OSHELL_ZMODEM_TRACE="1", OSHELL_BACKGROUND_TEST="1", OSHELL_HELPERS=str(helpers), OSHELL_REAL_LSZ=str(real/'lsz'), OSHELL_DATA_DIR=str(root/'config'), OSHELL_PROGRESS_TEST_ROOT=str(root))
    with (project/'validation/zmodem-progress-app.log').open('wb') as log:
        result = subprocess.run([str(app_bundle/'Contents/MacOS/OShell'), '--zmodem-progress-test'], env=env, stdout=log, stderr=log, timeout=160)
    report = json.loads((root/'result.json').read_text())
    if not report['passed']:
        print('FILES', [(str(f.relative_to(root)), f.stat().st_size) for name in ['download', 'upload'] for f in (root/name).glob('*')])
    (project/'validation/zmodem-progress-result.json').write_text(json.dumps(report, indent=2))
    if (root/'preview.png').exists(): (project/'validation/zmodem-progress-preview.png').write_bytes((root/'preview.png').read_bytes())
    print(json.dumps(report, indent=2))
    sys.exit(0 if report['passed'] and result.returncode == 0 else 1)
