#!/usr/bin/env python3
"""Print the faulting thread of a macOS .ips crash report as %0A-joined lines for a GitHub annotation."""
import sys, json
t = open(sys.argv[1]).read()
try:
    head, body = t.split('\n', 1)
    b = json.loads(body)
    out = [str(b.get('exception')), str(b.get('termination'))]
    for th in b.get('threads', []):
        if th.get('triggered'):
            for fr in th.get('frames', [])[:40]:
                out.append(str(fr.get('symbol')) + ' ' + str(fr.get('imageIndex')))
    print('%0A'.join(out))
except Exception as e:
    print('parse error', e, t[:800].replace('\n', '%0A'))
