#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Exercise index/history privacy checks using synthetic, disposable Git content."""
import argparse,importlib.util,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('audit',ROOT/'scripts/check-public-source.py');audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
with tempfile.TemporaryDirectory(prefix='oshell-public-check-') as folder:
 root=pathlib.Path(folder);audit.ROOT=root
 def git(*args):subprocess.run(['git','-C',str(root),*args],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 def report(history=None,app=None):return audit.inspect(argparse.Namespace(private_patterns=None,app=app,history=history,working_tree=False,index=True))
 git('init','-b','main');git('config','user.name','Fixture');git('config','user.email','fixture@example.test')
 (root/'README.md').write_text('Public project\n');git('add','README.md');assert report()['passed']
 git('commit','-m','fixture baseline')
 (root/'.env').write_text('not a real credential');git('add','.env');assert not report()['passed']
 git('rm','--cached','.env');(root/'.env').unlink()
 (root/'README.md').write_text('/Us'+'ers/private-fixture/project/file.swift');git('add','README.md');assert not report()['passed']
 git('commit','-m','synthetic path fixture')
 (root/'README.md').write_text('Public project\n');git('add','README.md');git('commit','-m','remove fixture')
 assert report()['passed'] and not report(history='main')['passed']
 (root/'token.txt').write_text('gh'+'p_'+'x'*36);git('add','token.txt');assert not report()['passed'];git('rm','-f','token.txt')
 (root/'link').symlink_to('../outside.key');git('add','link');assert not report()['passed'];git('rm','-f','link')
 (root/'link').symlink_to('README.md');git('add','link');assert report()['passed']
 app=root/'Fixture.app';app.mkdir();binary=app/'fixture';binary.write_bytes(b'\0'+str(pathlib.Path.home()).encode()+b'/private-file');assert not report(app=app)['passed']
print('PASS: clean index, excluded file, personal path, historical leak, token, unsafe/safe symlinks, binary build path')
