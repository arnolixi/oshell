#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Disposable SSH connection verifies tab grouping never reconnects or reauthenticates."""
import json, os, pathlib, secrets, socket, subprocess, tempfile, threading, time
import paramiko
project = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='oshell-named-groups-', dir='/tmp') as folder:
    root = pathlib.Path(folder); config = root/'config'; config.mkdir()
    key = paramiko.RSAKey.generate(2048); password = secrets.token_hex(24)
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(); port = listener.getsockname()[1]
    (config/'known_hosts').write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
    (root/'fixture.json').write_text(json.dumps({'port': str(port), 'password': password})); (root/'fixture.json').chmod(0o600)
    facts = {'transports': 0, 'authenticated': 0, 'shells': 0, 'exec': 0, 'rejected': 0}; lock = threading.Lock(); transports = []
    def shell(channel):
        try:
            time.sleep(.05); channel.send(b'GROUP_READY\r\nfixture@test:~$ '); line = bytearray()
            while True:
                data = channel.recv(4096)
                if not data: return
                for byte in data:
                    if byte in (10, 13):
                        value = bytes(line); line.clear()
                        if value: channel.sendall(b'REPLY_' + value + b'\r\nfixture@test:~$ ')
                    elif 32 <= byte < 127: line.append(byte)
        except (OSError, EOFError): pass
        finally: channel.close()
    class Server(paramiko.ServerInterface):
        def get_allowed_auths(self, user): return 'password'
        def check_auth_password(self, user, candidate):
            if user != 'fixture' or candidate != password: return paramiko.AUTH_FAILED
            deadline = time.time() + 20
            while not (root/'allow-auth').exists() and time.time() < deadline: time.sleep(.01)
            with lock: facts['authenticated'] += 1
            return paramiko.AUTH_SUCCESSFUL
        def check_channel_request(self, kind, channel_id):
            with lock:
                flag = root/'reject-next'
                if flag.exists():
                    flag.unlink(); facts['rejected'] += 1
                    return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
            return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self, *args): return True
        def check_channel_shell_request(self, channel):
            with lock: facts['shells'] += 1
            threading.Thread(target=shell, args=(channel,), daemon=True).start(); return True
        def check_channel_exec_request(self, *args):
            with lock: facts['exec'] += 1
            return False
    def client(sock):
        transport = paramiko.Transport(sock)
        with lock: facts['transports'] += 1; transports.append(transport)
        try:
            transport.add_server_key(key); transport.start_server(server=Server()); channels = []
            while transport.is_active():
                channel = transport.accept(1)
                if channel is not None: channels.append(channel)
        except (OSError, EOFError, paramiko.SSHException): pass
        finally: transport.close()
    def serve():
        while True:
            try: sock, _ = listener.accept()
            except OSError: return
            threading.Thread(target=client, args=(sock,), daemon=True).start()
    threading.Thread(target=serve, daemon=True).start()
    env = os.environ.copy(); env.update(OSHELL_DATA_DIR=str(config), OSHELL_BACKGROUND_TEST='1', OSHELL_NAMED_GROUPS_ROOT=folder)
    try:
        with open(project/'validation/named-groups-test.log', 'w') as log:
            result = subprocess.run([str(pathlib.Path(os.environ.get('OSHELL_TEST_APP', str(project/'dist/OShell.app')))/'Contents/MacOS/OShell'), '--named-tab-groups-test'], env=env, stdout=log, stderr=log, timeout=100)
        report = json.loads((root/'result.json').read_text())
        report['server'] = facts
        report['checks'].update(oneTransport=facts['transports']==1, oneAuthentication=facts['authenticated']==1, oneShellChannel=facts['shells']==1, noRemoteExec=facts['exec']==0, appExited=result.returncode==0)
        report['passed'] = all(report['checks'].values())
        (project/'validation/named-groups-result.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2)); raise SystemExit(0 if report['passed'] else 1)
    finally:
        listener.close()
        for transport in transports: transport.close()
