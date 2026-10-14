#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Loopback SSH/PTY + real lrz/lsz; cancel the actual upload chooser without files.
Requires the test app and the same Paramiko environment as run-file-tests.py.
"""
import json, os, pathlib, secrets, select, socket, subprocess, sys, tempfile, threading, time
import paramiko

project = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(os.environ.get('OSHELL_TEST_APP', project/'work/test-app/OShell.app'))
with tempfile.TemporaryDirectory(prefix='oshell-rz-cancel-', dir='/tmp') as temporary:
    root = pathlib.Path(temporary); remote = root/'remote'; remote.mkdir()
    key = paramiko.RSAKey.generate(2048); password = secrets.token_urlsafe(24)
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(); port = listener.getsockname()[1]
    (root/'fixture.json').write_text(json.dumps({'port': port, 'password': password})); (root/'fixture.json').chmod(0o600)
    (root/'known_hosts').write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
    facts = {'authentications': 0, 'shells': 0, 'cancelBursts': 0, 'returnInjectedDuringCancel': False}
    children = []; transports = []; stop = threading.Event()

    def shell(channel):
        master, slave = os.openpty()
        env = os.environ.copy()
        env.update(PS1='CANCEL_TEST> ', TERM='xterm-256color', HISTFILE='/dev/null',
                   PATH=str(app/'Contents/Helpers')+':/usr/bin:/bin', HOME=str(root), LC_ALL='C')
        # Acquire the slave as controlling terminal before exec, so Ctrl+C has
        # real terminal signal semantics. No preexec_fn in a threaded process.
        command = 'import fcntl,os,termios; fcntl.ioctl(0,termios.TIOCSCTTY,0); os.execv("/bin/bash",["bash","--noprofile","--norc","-i"])'
        child = subprocess.Popen([sys.executable, '-c', command], stdin=slave, stdout=slave, stderr=slave,
                                 start_new_session=True, cwd=remote, env=env)
        children.append(child); os.close(slave)
        delayed = bytearray(); release_at = 0.; cancel_at = 0.; mode = '0'
        try:
            while not stop.is_set() and child.poll() is None and not channel.closed:
                if cancel_at and time.monotonic() > max(release_at, cancel_at + .5):
                    mode = "0"
                if delayed and time.monotonic() >= release_at:
                    channel.sendall(delayed); delayed.clear()
                ready, _, _ = select.select([master, channel], [], [], .03)
                if channel in ready:
                    data = channel.recv(65536)
                    if not data: break
                    if b'\x18' * 5 in data:
                        facts['cancelBursts'] += 1; cancel_at = time.monotonic()
                        mode = (root/'cancel-mode').read_text()
                        release_at = cancel_at + (3 if mode == '2' else 0)
                    if cancel_at and time.monotonic()-cancel_at < .5 and b'\r' in data:
                        facts['returnInjectedDuringCancel'] = True
                    pending = memoryview(data)
                    while pending: pending = pending[os.write(master, pending):]
                if master in ready:
                    data = os.read(master, 65536)
                    if not data: break
                    # Model gateways/rz variants that return a prompt without
                    # a CAN response. Also delay all recovery output past 2s.
                    if mode != '0': data = data.replace(b'\x18', b'').replace(b'\x08', b'')
                    if time.monotonic() < release_at: delayed.extend(data)
                    else: channel.sendall(data)
        except (OSError, EOFError, paramiko.SSHException): pass
        finally:
            os.close(master); channel.close()
            if child.poll() is None:
                try: child.terminate()
                except ProcessLookupError: pass

    class Server(paramiko.ServerInterface):
        def check_auth_password(self, user, candidate):
            if user == 'fixture' and candidate == password:
                facts['authentications'] += 1; return paramiko.AUTH_SUCCESSFUL
            return paramiko.AUTH_FAILED
        def get_allowed_auths(self, user): return 'password'
        def check_channel_request(self, kind, channel_id):
            return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self, *args): return True
        def check_channel_shell_request(self, channel):
            facts['shells'] += 1; threading.Thread(target=shell, args=(channel,), daemon=True).start(); return True
    def client(sock):
        transport = paramiko.Transport(sock); transports.append(transport)
        try:
            transport.add_server_key(key); transport.start_server(server=Server()); channels = []
            while transport.is_active() and not stop.is_set():
                channel = transport.accept(.2)
                if channel is not None: channels.append(channel)
        except (OSError, EOFError, paramiko.SSHException): pass
        finally: transport.close()
    def serve():
        while not stop.is_set():
            try: sock, _ = listener.accept()
            except OSError: return
            threading.Thread(target=client, args=(sock,), daemon=True).start()
    threading.Thread(target=serve, daemon=True).start()
    env = os.environ.copy(); env.update(OSHELL_DATA_DIR=str(root/'config'), OSHELL_CANCEL_TEST_ROOT=str(root), ZDOTDIR=str(root))
    try:
        run = subprocess.run([str(app/'Contents/MacOS/OShell'), '--zmodem-cancel-test'], env=env, capture_output=True, timeout=120)
        result = json.loads((root/'result.json').read_text())
        result['checks'].update(oneSSHAuthentication=facts['authentications']==1, oneRemoteShell=facts['shells']==1,
                                allCancelPathsExercised=facts['cancelBursts']>=3, noInjectedReturn=not facts['returnInjectedDuringCancel'])
        result['passed'] = result['passed'] and all(result['checks'].values()) and run.returncode == 0
        (project/'validation/zmodem-cancel-result.json').write_text(json.dumps(result, indent=2))
        (project/'validation/zmodem-cancel-app.log').write_bytes(run.stdout+run.stderr)
        print(json.dumps(result, indent=2)); sys.exit(0 if result['passed'] else 1)
    finally:
        stop.set(); listener.close()
        for transport in transports: transport.close()
        for child in children:
            if child.poll() is None:
                try: child.terminate()
                except ProcessLookupError: pass
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try: child.kill()
                except ProcessLookupError: pass
                child.wait()
