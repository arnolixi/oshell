#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Disposable loopback endpoints for the app's local ping/curl/telnet/ssh tests."""
import http.server, json, os, pathlib, secrets, socket, socketserver, struct, subprocess, tempfile, threading, time
import paramiko
project = pathlib.Path(__file__).resolve().parent.parent
class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = (('LOCAL_CURL_BODY_' + 'x'*32 + '\n') * 25000 + 'LOCAL_CURL_TAIL\n').encode()
        self.send_response(200); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *_): pass
class Telnet(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.sendall(b'LOCAL_TELNET_READY\r\n')
        line = bytearray()
        while True:
            data = self.request.recv(1024)
            if not data: break
            for c in data:
                if c in (10,13):
                    value = bytes(line); line.clear()
                    if value == b'hello': self.request.sendall(b'LOCAL_TELNET_ECHO_OK\r\n')
                    if value == b'quit': return
                elif 32 <= c < 127: line.append(c)
class TCP(socketserver.ThreadingTCPServer): allow_reuse_address=True; daemon_threads=True
class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        if len(data) < 12: return
        end, labels = 12, []
        while end < len(data) and data[end]:
            length = data[end]; end += 1
            if length > 63 or end + length > len(data): return
            labels.append(data[end:end+length].decode('ascii', errors='replace')); end += length
        end += 1
        if end + 4 > len(data): return
        kind = struct.unpack('!H', data[end:end+2])[0]
        suffix = {'dig.oshell.test':42, 'lookup.oshell.test':43, 'host.oshell.test':44}.get('.'.join(labels).lower(),42)
        answer = b'\xc0\x0c' + struct.pack('!HHIH',1,1,60,4) + bytes([127,0,0,suffix]) if kind == 1 else b''
        response = data[:2] + struct.pack('!HHHHH',0x8180,1,1 if answer else 0,0,0) + data[12:end+4] + answer
        sock.sendto(response,self.client_address)
with tempfile.TemporaryDirectory(prefix='oshell-local-tools-',dir='/tmp') as directory:
    root=pathlib.Path(directory); key=paramiko.RSAKey.generate(2048)
    password=secrets.token_urlsafe(20); locale_requests=[]
    class SSH(paramiko.ServerInterface):
        def check_channel_env_request(self,channel,name,value):
            if name in (b'LANG',b'LANGUAGE') or name.startswith(b'LC_'):locale_requests.append(name.decode())
            return True
        def check_auth_password(self,u,p): return paramiko.AUTH_SUCCESSFUL if u=='oshell-local-test' and p==password else paramiko.AUTH_FAILED
        def get_allowed_auths(self,u): return 'password'
        def check_channel_request(self,kind,chanid): return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self,*args): return True
        def check_channel_shell_request(self,channel): return True
    ssh_socket=socket.socket();ssh_socket.bind(('127.0.0.1',0));ssh_socket.listen()
    ssh_port=ssh_socket.getsockname()[1]
    def ssh_client(sock):
        transport=paramiko.Transport(sock)
        try:
            transport.add_server_key(key);transport.start_server(server=SSH());channel=transport.accept(15)
            if channel is None:return
            time.sleep(.15);channel.send(b'LOCAL_SSH_READY\r\n');line=bytearray()
            while True:
                data=channel.recv(1024)
                if not data:break
                for c in data:
                    if c in (10,13):
                        value=bytes(line);line.clear()
                        if value==b'hello':channel.send(b'LOCAL_SSH_ECHO_OK\r\n')
                        if value==b'exit':channel.send_exit_status(0);channel.close();return
                    elif 32<=c<127:line.append(c)
        except (EOFError,OSError,paramiko.SSHException):pass
        finally:transport.close()
    def ssh_accept():
        while True:
            try: client,_=ssh_socket.accept()
            except OSError:return
            threading.Thread(target=ssh_client,args=(client,),daemon=True).start()
    http=http.server.ThreadingHTTPServer(('127.0.0.1',0),HTTP);telnet=TCP(('127.0.0.1',0),Telnet)
    dns=socketserver.ThreadingUDPServer(('127.0.0.1',0),DNS)
    for target in [http.serve_forever,telnet.serve_forever,dns.serve_forever,ssh_accept]:threading.Thread(target=target,daemon=True).start()
    (root/'known_hosts').write_text(f'[127.0.0.1]:{ssh_port} {key.get_name()} {key.get_base64()}\n')
    (root/'fixture.json').write_text(json.dumps(dict(httpPort=http.server_port,dnsPort=dns.server_address[1],telnetPort=telnet.server_address[1],sshPort=ssh_port,password=password)))
    env=os.environ.copy();env.update(OSHELL_DATA_DIR=str(root/'config'),OSHELL_LOCAL_TOOL_ROOT=str(root),LANG='en_US.UTF-8',LC_CTYPE='UTF-8',LC_ALL='C')
    app=None
    try:
        app=subprocess.Popen([str(project/'dist/OShell.app/Contents/MacOS/OShell'),'--local-tool-test'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        output,_=app.communicate(timeout=100)
        result=json.loads((root/'result.json').read_text())
        result['checks']['clientLocaleNotForwarded']=not locale_requests
        result['passed']=result['passed'] and all(result['checks'].values())
        (project/'validation/local-tools-result.json').write_text(json.dumps(result,indent=2))
        (project/'validation/local-tools-app.log').write_bytes(output)
        print(json.dumps(result,indent=2))
        if not result['passed'] or app.returncode:raise SystemExit(1)
    finally:
        if app is not None and app.poll() is None:
            app.terminate()
            try:app.wait(timeout=3)
            except subprocess.TimeoutExpired:app.kill();app.wait()
        http.shutdown();telnet.shutdown();dns.shutdown();ssh_socket.close()
