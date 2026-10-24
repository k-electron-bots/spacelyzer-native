#!/usr/bin/env python3
"""Regression control for the execution-evidence defect: a suite with a top-level exit before later checks must be
rejected by test-v1-capture.py's structural guard, quickly, and the real suite must keep the guard + floor."""
import pathlib, subprocess, sys, tempfile
src = pathlib.Path('scripts/test-v1-capture.py').read_text()
ok = 'MIN_EXECUTED = ' in src and src.rstrip().splitlines()[-1].startswith('sys.exit(') and "assert [l for l in lines if l.startswith('sys.exit(')]" in src
bad = src.replace("CONFIRM = '%d press", "sys.exit(0)\nCONFIRM = '%d press", 1)
assert bad != src
with tempfile.TemporaryDirectory() as t:
    p = pathlib.Path(t) / 'dead.py'; p.write_text(bad)
    r = subprocess.run([sys.executable, str(p)], capture_output=True, text=True, timeout=20, cwd='.')
caught = r.returncode != 0 and 'only top-level exit' in r.stderr
print(('ok   ' if ok else 'FAIL ') + 'real suite has the exit-last guard and an executed-check floor')
print(('ok   ' if caught else 'FAIL ') + 'mutated suite with an early exit before later checks is REJECTED by the guard')
sys.exit(0 if ok and caught else 1)
