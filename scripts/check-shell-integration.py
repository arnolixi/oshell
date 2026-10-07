#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Real interactive-shell PTY checks using disposable rc and history files."""
import json, os, pathlib, pty, re, select, shlex, signal, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'shell-integration/oshell-integration.sh'
checks = {}
shells = [('/bin/bash', 'bash-string'), ('/bin/bash', 'bash-old-array'), ('/bin/zsh', 'zsh')]
if pathlib.Path('/opt/homebrew/bin/bash').exists(): shells += [('/opt/homebrew/bin/bash', 'bash-array')]
for binary, label in shells:
    with tempfile.TemporaryDirectory(prefix='oshell-hook-', dir='/tmp') as directory:
        root = pathlib.Path(directory); bindir = root / 'bin'; bindir.mkdir()
        hostname = bindir / 'hostname'
        hostname.write_text('#!/bin/sh\ncase "$1" in -I) printf "127.0.0.1 10.40.0.9\\n";; *) printf "fixture-host\\n";; esac\n')
        hostname.chmod(0o700)
        rc = root / ('.zshrc' if label == 'zsh' else 'bashrc')
        setup = 'HISTFILE=' + shlex.quote(str(root / 'history')) + '\nHISTSIZE=200\n'
        if label == 'zsh': setup += 'SAVEHIST=200\nsetopt APPEND_HISTORY\nprecmd() { __prior_status=$?; }\n'
        else:
            setup += 'HISTCONTROL=\nHISTIGNORE=\n__prior_hook() { __prior_status=$?; }\n'
            setup += "PROMPT_COMMAND=( '__prior_hook' ':' )\n" if 'array' in label else "PROMPT_COMMAND='__prior_hook'\n"
        setup += 'source ' + shlex.quote(str(SCRIPT)) + '\nsource ' + shlex.quote(str(SCRIPT)) + '\nPS1="READY> "\n'
        rc.write_text(setup)
        pid, fd = pty.fork()
        if pid == 0:
            env = dict(os.environ, TERM='xterm-256color', PATH=str(bindir)+':/usr/bin:/bin:/usr/sbin:/sbin', ZDOTDIR=str(root), SSH_CONNECTION='198.51.100.1 45000 10.30.0.8 22')
            env.pop('OSHELL_INTEGRATION', None); env.pop('PROMPT_COMMAND', None)
            args = [binary, '-d', '-i'] if label == 'zsh' else [binary, '--noprofile', '--rcfile', str(rc), '-i']
            os.execve(binary, args, env)
        all_output = bytearray()
        def read_prompt():
            data = bytearray(); deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                ready, _, _ = select.select([fd], [], [], .1)
                if ready:
                    try: part = os.read(fd, 65536)
                    except OSError: break
                    data.extend(part); all_output.extend(part)
                    if re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', data).endswith(b'READY> '): return bytes(data)
            raise RuntimeError(label + ': prompt timed out: ' + repr(data[-500:]))
        try:
            first = read_prompt()
            frame = b'\x1b]777;OShellHost=1;fixture-host|10.30.0.8|\x07'
            checks[label+'-report'] = frame in first
            checks[label+'-source-idempotent'] = first.count(frame) == 1
            os.write(fd, b'false\r'); read_prompt()
            os.write(fd, b'printf "STATUS=%s\\n" "$__prior_status"\r'); status = read_prompt()
            checks[label+'-previous-hook-exit-status'] = b'\r\nSTATUS=1\r\n' in status
            os.write(fd, b'echo USER_COMMAND_PRESERVED\r'); read_prompt()
            os.write(fd, b'unset SSH_CONNECTION\r'); fallback = read_prompt()
            checks[label+'-interface-fallback'] = b'fixture-host||127.0.0.1 10.40.0.9' in fallback
            os.write(fd, b'exit\r')
            deadline = time.monotonic()+8
            while time.monotonic() < deadline:
                waited, _ = os.waitpid(pid, os.WNOHANG)
                if waited: break
                
                ready, _, _ = select.select([fd], [], [], .05)
                if ready:
                    try: all_output.extend(os.read(fd, 65536))
                    except OSError: pass
            else: raise RuntimeError(label + ': shell did not exit: ' + repr(all_output[-1500:]))
            history = (root/'history').read_text()
            checks[label+'-user-history-preserved'] = 'USER_COMMAND_PRESERVED' in history and 'false' in history
            checks[label+'-no-probe-history'] = all(x not in history for x in ['__oshell_report', 'hostname', 'OShellHost', 'PROMPT_COMMAND'])
        finally:
            os.close(fd)
            try: os.kill(pid, signal.SIGHUP)
            except ProcessLookupError: pass
report = {'passed': all(checks.values()), 'checks': checks}
(ROOT/'validation/shell-integration-script-result.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2)); raise SystemExit(0 if report['passed'] else 1)
