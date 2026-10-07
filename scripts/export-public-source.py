#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
"""Export only audited committed source. Never archives the entire working directory."""
import argparse,pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ref',default='HEAD');parser.add_argument('--output',type=pathlib.Path,required=True)
args=parser.parse_args()
commit=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','--verify',args.ref+'^{commit}'],text=True).strip()
subprocess.run([sys.executable,str(ROOT/'scripts/check-public-source.py'),'--history',commit],check=True)
if args.output.exists():raise SystemExit('Output already exists; choose a new filename')
args.output.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['git','-C',str(ROOT),'archive','--format=tar.gz','--prefix=OShell/','--output',str(args.output.resolve()),commit],check=True)
print('Created audited source archive:',args.output)
