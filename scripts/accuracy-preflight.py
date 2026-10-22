#!/usr/bin/env python3
"""Records what THIS filesystem/user can represent, before the accuracy check runs, so a case it cannot exercise is NOT-RUN in the artifact, not a silent pass.
Probes (in a private temp dir it deletes): non-root user, chmod-000 enforcement (a mode-000 directory really cannot be listed), case-insensitive names,
Unicode-normalizing names, non-UTF-8 names (APFS: EILSEQ 92), unix socket bind, free disk. Usage: accuracy-preflight.py OUT.json. Exit 0 always; the gate decides."""
import json, os, platform, shutil, socket, sys, tempfile, unicodedata
r = dict(platform=platform.platform(), uid=os.getuid(), notrun=[]); d = os.path.realpath(tempfile.mkdtemp(prefix='accpf-'))
try:
    r['non_root'] = os.getuid() != 0
    os.mkdir(d + '/n'); os.chmod(d + '/n', 0)
    try: os.listdir(d + '/n'); r['chmod000_enforced'] = False
    except PermissionError: r['chmod000_enforced'] = True
    os.chmod(d + '/n', 0o700)
    open(d + '/Ab', 'w').write('1'); open(d + '/aB', 'w').write('2')
    r['case_sensitive'] = len([x for x in os.listdir(d) if x.lower() == 'ab']) == 2
    n1, n2 = unicodedata.normalize('NFC', 'caf\u00e9'), unicodedata.normalize('NFD', 'caf\u00e9')
    open(d + '/' + n1, 'w').write('1'); open(d + '/' + n2, 'w').write('2')
    r['nfc_nfd_distinct'] = len([x for x in os.listdir(d) if unicodedata.normalize('NFC', x) == n1]) == 2
    try: open(os.fsencode(d) + b'/bad\xff', 'wb').write(b'x'); r['non_utf8_names'] = True
    except OSError as e: r['non_utf8_names'] = False; r['non_utf8_errno'] = e.errno
    try: s = socket.socket(socket.AF_UNIX); s.bind(d + '/sock'); s.close(); r['unix_socket'] = True
    except OSError: r['unix_socket'] = False
    r['tmp_free_mib'] = shutil.disk_usage(d).free >> 20
finally:
    try: os.chmod(d + '/n', 0o700)
    except OSError: pass
    shutil.rmtree(d, ignore_errors=True)
for k, why in (('non_root', 'running as root: chmod-000 unreadable accounting cannot be exercised'), ('chmod000_enforced', 'chmod 000 is not enforced here'),
               ('case_sensitive', 'filesystem is case-insensitive: case variants collapse'), ('nfc_nfd_distinct', 'filesystem normalizes Unicode: NFC/NFD names collapse'),
               ('non_utf8_names', 'filesystem refuses non-UTF-8 names (lossy-SKIP cases not exercised)'), ('unix_socket', 'unix socket bind failed')):
    if not r[k]: r['notrun'].append(why); print('NOT-RUN:', why)
print(json.dumps(r, indent=1)); open(sys.argv[1], 'w').write(json.dumps(r, indent=1))
