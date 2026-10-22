#!/usr/bin/env python3
"""Durable regression for the nested-func actor-isolation error that broke run 39855017271 (SpacelyzerApp.swift:66).
Part 1 (compiler, Linux-capable): typechecks a minimal reproducer of the exact pattern - a local func inside a MainActor closure that touches
a MainActor model and a MainActor static helper, also called from @MainActor schedule closures. The OLD form must FAIL with the two Mac
diagnostics, the FIXED form must PASS, under -swift-version 5 and 6. This proves the compiler rule, NOT that the app (AppKit) compiles.
Part 2 (static, always runs): in Sources/Spacelyzer/SpacelyzerApp.swift every nested `func mark(` must carry @MainActor, so the demo
handshake cannot silently go back to the nonisolated form. Static source check, not compilation.
swiftc: $SPZ_SWIFTC, else PATH. No swiftc => Part 1 is NOT-RUN and the script exits 3 (set SPZ_ALLOW_NO_SWIFTC=1 to accept that explicitly)."""
import os, re, shutil, subprocess, sys
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
F = R + '/scripts/fixtures/'
fails = []
def ck(n, ok, d=''):
    print(('ok   ' if ok else 'FAIL ') + n + ('' if ok else ' :: ' + d)); (ok or fails.append(n))
src = open(R + '/Sources/Spacelyzer/SpacelyzerApp.swift').read().split('\n')
marks = [(i + 1, l) for i, l in enumerate(src) if re.match(r'\s*(@MainActor\s+)?func mark\(', l)]
ck('found the demo mark() declaration', len(marks) >= 1)
for n, l in marks: ck(f'SpacelyzerApp.swift:{n} mark() is @MainActor (static source check)', '@MainActor' in l, l.strip())
swiftc = os.environ.get('SPZ_SWIFTC') or shutil.which('swiftc')
if not swiftc:
    print('NOT-RUN compiler part: no swiftc'); sys.exit(0 if (os.environ.get('SPZ_ALLOW_NO_SWIFTC') == '1' and not fails) else 3)
ver = subprocess.run([swiftc, '--version'], capture_output=True, text=True).stdout.split('\n')[0]; print('compiler:', ver)
def tc(fix, sv):
    r = subprocess.run([swiftc, '-swift-version', sv, '-typecheck', F + fix], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr
for sv in ('5', '6'):
    rc, out = tc('isolation-mark-old.swift', sv)
    ck(f'OLD nested mark() FAILS (swift {sv}) with both Mac diagnostics', rc != 0 and "call to main actor-isolated static method 'stateLine(step:alertShown:)' in a synchronous nonisolated context" in out and "main actor-isolated property 'removalMessage' can not be referenced from a nonisolated context" in out, out[-300:])
    rc, out = tc('isolation-mark-fixed.swift', sv)
    ck(f'FIXED @MainActor mark() PASSES (swift {sv})', rc == 0, out[-300:])
sys.exit(1 if fails else 0)
