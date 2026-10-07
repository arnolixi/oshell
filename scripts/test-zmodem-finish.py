#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Application + real Bash/lrz/lsz. Force coalesced ZFIN retries, like a delayed ACK.
No real remote hosts or user data. The receiver wrapper only alters ZFIN output.
"""
import json, os, pathlib, subprocess, sys, tempfile
project = pathlib.Path(__file__).resolve().parent.parent
mode = sys.argv[1] if len(sys.argv) > 1 else 'burst'
label = sys.argv[2] if len(sys.argv) > 2 else mode
with tempfile.TemporaryDirectory(prefix='oshell-zfin-', dir='/tmp') as temporary:
    root = pathlib.Path(temporary); helpers = root/'helpers'; helpers.mkdir()
    app_bundle = pathlib.Path(os.environ.get('OSHELL_TEST_APP', str(project/'dist/OShell.app')))
    real_helpers = app_bundle/'Contents/Helpers'
    for name in ['OShellAskpass', 'OShellProxy']: (helpers/name).symlink_to(real_helpers/name)
    if mode in ('burst', 'early-exit'):
        wrapper = helpers/'lrz'
        wrapper.write_text('#!' + sys.executable + '\n' + '''import os, subprocess, sys, time
if '--junk-path' not in sys.argv:
    os.execv(os.environ['OSHELL_REAL_LRZ'], [os.environ['OSHELL_REAL_LRZ'], *sys.argv[1:]])
p = subprocess.Popen([os.environ['OSHELL_REAL_LRZ'], *sys.argv[1:]], stdout=subprocess.PIPE)
marker = b'**\\x18B0800000000022d\\r\\x8a'
pending = b''
while True:
    data = os.read(p.stdout.fileno(), 65536)
    if not data: break
    pending += data
    # Retain only potential partial markers, keeping normal protocol output live.
    while pending:
        at = pending.find(marker)
        if at >= 0:
            os.write(1, pending[:at] + marker)
            if os.environ.get('OSHELL_FINISH_MODE') == 'early-exit':
                p.terminate(); p.wait(); sys.exit(0)
            for _ in range(2):
                time.sleep(.03)
                os.write(1, marker)
            pending = pending[at+len(marker):]
            continue
        retained = next((n for n in range(min(len(marker)-1, len(pending)), 0, -1) if pending.endswith(marker[:n])), 0)
        if len(pending) > retained: os.write(1, pending[:len(pending)-retained])
        pending = pending[len(pending)-retained:] if retained else b''
        break
if pending: os.write(1, pending)
sys.exit(p.wait())
''')
        wrapper.chmod(0o700)
        sender = helpers/'lsz'
        sender.write_text('#!' + sys.executable + '\n' + '''import os, subprocess, sys, time
p = subprocess.Popen([os.environ['OSHELL_REAL_LSZ'], *sys.argv[1:]], stdout=subprocess.PIPE)
ending = False
tail = b''
while True:
    data = os.read(p.stdout.fileno(), 65536)
    if not data: break
    if b'**\\x18B0800000000022d' in tail + data: ending = True
    tail = (tail + data)[-17:]
    if ending and b'OO' in data: time.sleep(.3)
    os.write(1, data)
sys.exit(p.wait())
''')
        sender.chmod(0o700)
    elif mode == 'missing-oo':
        (helpers/'lrz').symlink_to(real_helpers/'lrz')
        sender = helpers/'lsz'
        sender.write_text('#!' + sys.executable + '\n' + """import os, subprocess, sys
if '-vv' in sys.argv:
    os.execv(os.environ['OSHELL_REAL_LSZ'], [os.environ['OSHELL_REAL_LSZ'], *sys.argv[1:]])
p = subprocess.Popen([os.environ['OSHELL_REAL_LSZ'], *sys.argv[1:]], stdout=subprocess.PIPE)
ending = False
tail = b''
while True:
    data = os.read(p.stdout.fileno(), 65536)
    if not data: break
    if b'**\\x18B0800000000022d' in tail + data: ending = True
    tail = (tail + data)[-17:]
    if ending: data = data.replace(b'OO', b'')
    while data:
        count = os.write(1, data); data = data[count:]
sys.exit(p.wait())
""")
        sender.chmod(0o700)
    elif mode == 'stderr-hold':
        # Reproduce an inherited stderr descriptor remaining open after the
        # receiver has completed its protocol and exited successfully.
        wrapper = helpers/'lrz'
        wrapper.write_text('#!' + sys.executable + '\n' + """import os, subprocess, sys
if '--junk-path' not in sys.argv:
    os.execv(os.environ['OSHELL_REAL_LRZ'], [os.environ['OSHELL_REAL_LRZ'], *sys.argv[1:]])
p = subprocess.run([os.environ['OSHELL_REAL_LRZ'], *sys.argv[1:]])
subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(4)'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
sys.exit(p.returncode)
""")
        wrapper.chmod(0o700)
        (helpers/'lsz').symlink_to(real_helpers/'lsz')
    else:
        (helpers/'lrz').symlink_to(real_helpers/'lrz')
        (helpers/'lsz').symlink_to(real_helpers/'lsz')
    env = os.environ.copy(); env.update(OSHELL_BACKGROUND_TEST="1", OSHELL_HELPERS=str(helpers), OSHELL_FINISH_MODE=mode, OSHELL_REAL_LRZ=str(real_helpers/'lrz'), OSHELL_REAL_LSZ=str(real_helpers/'lsz'), OSHELL_DATA_DIR=str(root/'config'), OSHELL_ZMODEM_TEST_ROOT=str(root))
    app = subprocess.run([str(app_bundle/'Contents/MacOS/OShell'), '--zmodem-regression-test'], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    result = json.loads((root/'result.json').read_text())
    result['mode'] = mode
    (project/f'validation/zfin-{label}-result.json').write_text(json.dumps(result, indent=2))
    (project/f'validation/zfin-{label}-screen.txt').write_bytes((root/'screen.txt').read_bytes())
    (project/f'validation/zfin-{label}-app.log').write_bytes(app.stdout)
    print(json.dumps(result, indent=2)); sys.exit(0 if result['passed'] and app.returncode == 0 else 1)
