#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors
import argparse, json, pathlib
import code_signing
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Sign using the pinned OShell identity, or verify that identity.')
    parser.add_argument('app', type=pathlib.Path, nargs='?'); parser.add_argument('--verify', action='store_true')
    parser.add_argument('--preflight', action='store_true', help='test the fixed signing identity using a disposable executable')
    args = parser.parse_args()
    if args.preflight and (args.app or args.verify): parser.error('--preflight does not accept an app or --verify')
    if not args.preflight and args.app is None: parser.error('app is required unless --preflight is used')
    try: print(json.dumps(code_signing.preflight() if args.preflight else code_signing.verify(args.app) if args.verify else code_signing.sign_app(args.app)))
    except (RuntimeError, ValueError, OSError) as error: parser.exit(1, str(error)+'\n')
