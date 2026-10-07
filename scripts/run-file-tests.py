#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

"""Run using a Python environment containing Paramiko; fixtures are disposable."""
import json, os, pathlib, subprocess, sys, tempfile, time
project=pathlib.Path(__file__).resolve().parent.parent
preview="--preview" in sys.argv
tabs="--tabs" in sys.argv
with tempfile.TemporaryDirectory(prefix='oshell-files-',dir='/tmp') as folder:
    root=pathlib.Path(folder); server=client=None
    try:
        with (root/'server.log').open('w') as log:
            server=subprocess.Popen([sys.executable,str(project/'scripts/file-test-server.py'),folder],stdout=log,stderr=log)
            deadline=time.time()+10
            while not (root/'fixture.json').exists() and time.time()<deadline: time.sleep(.05)
            env=os.environ.copy();env.update(OSHELL_DATA_DIR=str(root/'Application Support'/'OShell'),OSHELL_FILE_TEST_ROOT=folder,LANG='en_US.UTF-8',LC_CTYPE='UTF-8',LC_ALL='C')
            app=pathlib.Path(os.environ.get('OSHELL_TEST_APP',str(project/'dist/OShell.app')))
            if not preview: env['OSHELL_BACKGROUND_TEST']='1'
            if preview:
                import shutil,plistlib
                app=root/'OShellPreview.app';shutil.copytree(project/'dist/OShell.app',app)
                plist=app/'Contents/Info.plist';info=plistlib.loads(plist.read_bytes());info['CFBundleIdentifier']='app.oshell.operator-preview';info['CFBundleName']='OShellPreview';info['CFBundleDisplayName']='OShellPreview';plist.write_bytes(plistlib.dumps(info))
                subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
                print('PREVIEW_APP='+str(app),flush=True)
            args=[str(app/'Contents/MacOS/OShell'),'--filetabs-integration-test' if tabs else '--file-feature-test']+(['--keep-open'] if preview else [])
            client=subprocess.Popen(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            output,_=client.communicate(timeout=None if preview else 150)
            result=json.loads((root/'file-result.json').read_text())
            result['checks']['clientLocaleNotForwarded']=not (root/'locale-requests.log').exists()
            result['passed']=result['passed'] and all(result['checks'].values())
            (project/('validation/filetabs-network-result.json' if tabs else 'validation/file-features-result.json')).write_text(json.dumps(result,indent=2))
            (project/('validation/filetabs-network-app.log' if tabs else 'validation/file-features-app.log')).write_bytes(output)
            print(json.dumps(result,indent=2))
            if not result['passed']: print((root/'server.log').read_text()[-6000:])
            sys.exit(0 if result['passed'] and client.returncode==0 else 1)
    finally:
        for process in [client,server]:
            if process and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill();process.wait()
