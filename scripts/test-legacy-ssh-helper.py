#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Own PTY + loopback SSH server: askpass without force, and explicit resize."""
import fcntl,json,os,pathlib,pty,secrets,select,shlex,signal,socket,struct,threading,time,tempfile
import paramiko
project=pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='oshell-legacy-ssh-',dir='/tmp') as directory:
    root=pathlib.Path(directory);password=secrets.token_urlsafe(24);key=paramiko.RSAKey.generate(2048)
    sock=socket.socket();sock.bind(('127.0.0.1',0));sock.listen();port=sock.getsockname()[1]
    known=root/'known_hosts';known.write_text(f'[127.0.0.1]:{port} {key.get_name()} {key.get_base64()}\n')
    ask=root/'askpass';ask.write_text('#!/bin/sh\nprintf \'%s\\n\' '+shlex.quote(password)+'\n');ask.chmod(0o700)
    resized=threading.Event();facts={'authenticated':False,'initialPTY':False,'resized':False}
    transports=[]
    class Server(paramiko.ServerInterface):
        def get_allowed_auths(self,username):return 'password'
        def check_auth_password(self,username,value):
            good=username=='fixture' and value==password;facts['authenticated']=good
            return paramiko.AUTH_SUCCESSFUL if good else paramiko.AUTH_FAILED
        def check_channel_request(self,kind,chanid):return paramiko.OPEN_SUCCEEDED if kind=='session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        def check_channel_pty_request(self,channel,term,width,height,*_):facts['initialPTY']=width==80 and height==24;return True
        def check_channel_window_change_request(self,channel,width,height,*_):
            if width==120 and height==40:facts['resized']=True;resized.set()
            return True
        def check_channel_exec_request(self,channel,command):
            def work():
                channel.sendall(b'SHIM_READY\r\n');resized.wait(8)
                channel.sendall(b'SHIM_DONE\r\n');channel.send_exit_status(0);channel.close()
            threading.Thread(target=work,daemon=True).start();return True
    def serve():
        connection,_=sock.accept();transport=paramiko.Transport(connection);transports.append(transport)
        transport.add_server_key(key);transport.start_server(server=Server())
        while transport.is_active():time.sleep(.02)
    thread=threading.Thread(target=serve,daemon=True);thread.start()
    helper=pathlib.Path(os.environ.get('OSHELL_LEGACY_SSH_HELPER',str(project/'work/release/legacy/OShell.app/Contents/Helpers/OShellSSH')))
    pid,fd=pty.fork()
    if pid==0:
        fcntl.ioctl(0,__import__('termios').TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
        env=dict(os.environ,SSH_ASKPASS=str(ask),TERM='xterm-256color');env.pop('SSH_ASKPASS_REQUIRE',None);env.pop('DISPLAY',None)
        os.execve(str(helper),[str(helper),'-F','/dev/null','-tt','-p',str(port),'-o','StrictHostKeyChecking=yes','-o',f'UserKnownHostsFile={known}','-o','PreferredAuthentications=password','-o','PubkeyAuthentication=no','fixture@127.0.0.1','probe'],env)
    data=b'';sent=False;status=None
    try:
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            if select.select([fd],[],[],.05)[0]:
                try:data+=os.read(fd,8192)
                except OSError:pass
            if b'SHIM_READY' in data and not sent:
                fcntl.ioctl(fd,__import__('termios').TIOCSWINSZ,struct.pack('HHHH',40,120,0,0));os.kill(pid,signal.SIGWINCH);sent=True
            done,value=os.waitpid(pid,os.WNOHANG)
            if done:status=os.waitstatus_to_exitcode(value);break
        facts['cleanExit']=status==0 and b'SHIM_DONE' in data
    finally:
        if status is None:
            os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)
        os.close(fd);sock.close()
        for transport in transports:transport.close()
    report={'passed':all(facts.values()),'checks':facts,'exitStatus':status}
    if not report['passed']: print(data.decode(errors='replace').replace(password,'[REDACTED]'))
    (project/'validation/package-legacy-ssh-helper.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2));raise SystemExit(0 if report['passed'] else 1)
