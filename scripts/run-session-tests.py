#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Run with a Python environment containing paramiko. Never uses real credentials."""
import json, os, socket, subprocess, sys, tempfile, time
from pathlib import Path
project = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='oshell-session-', dir='/tmp') as folder:
    root = Path(folder); server = client = None
    try:
        with (root/'server.log').open('w') as log:
            server = subprocess.Popen([sys.executable, str(project/'scripts/session-test-server.py'), folder], stdout=log, stderr=log)
            deadline = time.time() + 10
            while not (root/'fixture.json').exists() and time.time() < deadline: time.sleep(.05)
            env = os.environ.copy(); env.update(OSHELL_DATA_DIR=str(root/'client'), OSHELL_SESSION_TEST_ROOT=folder,
                                               LANG='en_US.UTF-8', LC_CTYPE='UTF-8', LC_ALL='C')
            client = subprocess.Popen([str(project/'dist/OShell.app/Contents/MacOS/OShell'), '--session-test'], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            tunnels = subprocess.run([sys.executable, str(project/'scripts/check-session-tunnels.py'), folder], capture_output=True, timeout=40)
            output, _ = client.communicate(timeout=40)
            result = json.loads((root/'client-result.json').read_text())
            result['server'] = json.loads((root/'server-result.json').read_text())
            transcript = (root/'session.log').read_text(errors='replace')
            result['checks']['controlSocketProbeDoesNotPrintErrors'] = not any(marker in transcript for marker in ['mux_master_', 'mux_client_', 'Broken pipe'])
            result['checks']['configuredRemoteForwardRequestedOnce'] = result['server']['remoteForwardRequests'] == 1
            result['checks']['clientLocaleNotForwarded'] = result['server']['localeRequests'] == 0
            f = json.loads((root/'fixture.json').read_text()); closed = True
            time.sleep(.2)
            for field in ['localPort', 'remotePort', 'dynamicPort']:
                try:
                    with socket.create_connection(('127.0.0.1', f[field]), timeout=.5): closed = False
                except OSError: pass
            result['checks']['tunnelListenersClosedOnShutdown'] = closed
            result['passed'] = all(result['checks'].values()) and client.returncode == 0
            (project/'validation/session-features-result.json').write_text(json.dumps(result, indent=2))
            (project/'validation/session-features-app.log').write_bytes(output)
            print(json.dumps(result, indent=2))
            sys.exit(0 if result['passed'] else 1)
    finally:
        for process in [client, server]:
            if process and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
