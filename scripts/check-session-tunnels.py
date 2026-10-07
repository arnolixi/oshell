#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

import json, socket, struct, sys, time
from pathlib import Path
root = Path(sys.argv[1]); deadline = time.time() + 35
while not (root/'client-ready').exists() and time.time() < deadline: time.sleep(.1)
f = json.loads((root/'fixture.json').read_text()); results = {}
def exact(s, n):
    out = b''
    while len(out) < n:
        data = s.recv(n-len(out))
        if not data: raise EOFError()
        out += data
    return out
for name in ['localPort', 'remotePort', 'dynamicPort']:
    try:
        with socket.create_connection(('127.0.0.1', f[name]), timeout=5) as s:
            if name == 'dynamicPort':
                s.sendall(b'\5\1\0'); assert exact(s, 2) == b'\5\0'
                s.sendall(b'\5\1\0\1\x7f\0\0\1' + struct.pack('!H', f['echoPort']))
                response = exact(s, 4); assert response[1] == 0
                exact(s, (4 if response[3] == 1 else 16) + 2)
            payload = b'OSHELL_TUNNEL_CHECK' * 1000; s.sendall(payload); results[name] = exact(s, len(payload)) == payload
    except Exception: results[name] = False
(root/'tunnel-result.json').write_text(json.dumps(results, indent=2)); print(results)
