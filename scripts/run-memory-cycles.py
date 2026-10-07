#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""48 disposable USM-style SSH sessions with scrollback, exit, close and reuse."""
import json, os, pathlib, secrets, socket, subprocess, sys, tempfile, threading, time
import paramiko
project = pathlib.Path(__file__).resolve().parent.parent
label = sys.argv[1] if len(sys.argv) > 1 else 'memory-cycles'
with tempfile.TemporaryDirectory(prefix='oshell-memory-cycles-', dir='/tmp') as directory:
    root = pathlib.Path(directory); key = paramiko.RSAKey.generate(2048); password = secrets.token_hex(20)
    listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(32); port = listener.getsockname()[1]
    facts = dict(authenticated=0, activeTransports=0, shells=0); lock = threading.Lock()
    payload = ''.join(f'\x1b[3{i%7+1}m{i:04d} 主机内存测试 error warning '+ 'x'*100+'\x1b[0m\r\n' for i in range(3200)).encode() + b'MEMORY_OUTPUT_COMPLETE\r\n'
    def session(channel, round_number):
        try:
            channel.sendall(payload)
            # End the remote shell after the app records its loaded state.
            # This exercises normal SSH EOF/exit, independently of keyboard routing.
            while True:
                if channel.closed: return
                try: phase = json.loads((root/'phase.json').read_text())
                except (FileNotFoundError, json.JSONDecodeError): phase = {}
                if phase.get('phase') == f'open_{round_number}':
                    channel.send_exit_status(0); return
                time.sleep(.05)
        except (EOFError, OSError): pass
        finally: channel.close()
    class Server(paramiko.ServerInterface):
        def get_allowed_auths(self, user): return 'password'
        def check_auth_password(self, user, value):
            if user != 'test' or value != password: return paramiko.AUTH_FAILED
            with lock: facts['authenticated'] += 1
            return paramiko.AUTH_SUCCESSFUL
        def check_channel_request(self, kind, chanid): return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self, *args): return True
        def check_channel_shell_request(self, channel):
            with lock:
                facts['shells'] += 1; round_number = (facts['shells']-1)//16+1
            threading.Thread(target=session, args=(channel,round_number), daemon=True).start(); return True
    def connection(sock):
        transport = paramiko.Transport(sock)
        with lock: facts['activeTransports'] += 1
        try:
            transport.add_server_key(key); transport.start_server(server=Server()); channels=[]
            while transport.is_active():
                channel=transport.accept(1)
                if channel is not None: channels.append(channel)
        except (EOFError,OSError,paramiko.SSHException): pass
        finally:
            transport.close()
            with lock: facts['activeTransports'] -= 1
    def accept():
        while True:
            try: sock,_ = listener.accept()
            except OSError: return
            threading.Thread(target=connection,args=(sock,),daemon=True).start()
    threading.Thread(target=accept,daemon=True).start()
    (root/'fixture.json').write_text(json.dumps(dict(port=port,password=password))); (root/'fixture.json').chmod(0o600)
    (root/'known_hosts').write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
    env=os.environ.copy(); env.update(OSHELL_DATA_DIR=str(root/'config'),OSHELL_MEMORY_CYCLE_ROOT=str(root))
    app=None
    try:
        binary=os.environ.get('OSHELL_MEMORY_BINARY',str(project/'dist/OShell.app/Contents/MacOS/OShell'))
        with (project/'validation'/f'{label}.log').open('wb') as log:
            app=subprocess.Popen([binary,'--memory-cycles'],env=env,stdout=log,stderr=log)
            print(f'Test PID {app.pid}; fixture {root}',flush=True)
            app.wait(timeout=240)
        result=json.loads((root/'result.json').read_text()); time.sleep(1)
        result['server']=facts; result['checks']['all48Authenticated']=facts['authenticated']==48
        result['checks']['allTransportsClosed']=facts['activeTransports']==0
        result['passed']=result['passed'] and all(result['checks'].values()) and app.returncode==0
        (project/'validation'/f'{label}.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result,indent=2)); sys.exit(0 if result['passed'] else 1)
    finally:
        listener.close()
        if app is not None and app.poll() is None:
            app.terminate()
            try: app.wait(timeout=5)
            except subprocess.TimeoutExpired: app.kill(); app.wait()
