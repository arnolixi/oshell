#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Real lrz/lsz streaming interoperability, batch names, binary bytes and collision tests."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

helpers = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="oshell-zmodem-") as temporary:
    root = Path(temporary)
    source, destination = root / "source", root / "destination"
    source.mkdir(); destination.mkdir()
    files = [source / "中文 空格.bin", source / "small.txt", source / ".env"]
    files[0].write_bytes(bytes(range(256)) * 4096)
    files[1].write_text("OShell ZMODEM 测试\n", encoding="utf-8")
    files[2].write_text("OSHELL_TEST=1\n", encoding="utf-8")
    results = []
    for iteration in range(2):
        a_read, a_write = os.pipe()
        b_read, b_write = os.pipe()
        receiver = subprocess.Popen([str(helpers / "lrz"), "-b", "-e", "-E", "--junk-path"],
                                    cwd=destination, stdin=a_read, stdout=b_write, stderr=subprocess.PIPE)
        sender = subprocess.Popen([str(helpers / "lsz"), "-b", "-e", "-f", "-w", "16384", "--", *map(str, files)],
                                  stdin=b_read, stdout=a_write, stderr=subprocess.PIPE)
        for descriptor in [a_read, a_write, b_read, b_write]:
            os.close(descriptor)
        try:
            _, send_errors = sender.communicate(timeout=30)
            _, receive_errors = receiver.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            sender.kill(); receiver.kill()
            raise
        assert sender.returncode == receiver.returncode == 0, (send_errors, receive_errors)
        for file in files:
            received = destination / (file.name + (".0" if iteration else ""))
            assert received.exists(), list(destination.iterdir())
            assert hashlib.sha256(file.read_bytes()).digest() == hashlib.sha256(received.read_bytes()).digest()
            results.append({"name": received.name, "bytes": received.stat().st_size, "sha256Match": True})
    print(json.dumps({"passed": True, "files": results}, ensure_ascii=False, indent=2))
