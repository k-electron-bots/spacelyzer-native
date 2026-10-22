#!/usr/bin/env python3
"""Test double for `spz`: runs the real `spz dump ROOT` (SPZ_REAL) and applies ONE tamper named by TAMPER, so controls prove the comparison catches it."""
import os, subprocess, sys
real, root, mode = os.environ['SPZ_REAL'], sys.argv[2], os.environ['TAMPER']
lines = subprocess.run([real, 'dump', root], capture_output=True, text=True).stdout.splitlines()
def pick(kind, skip=1):
    n = 0
    for i, l in enumerate(lines):
        if l.split('\t')[0] == kind and l.split('\t')[2] != root:
            n += 1
            if n == skip: return i
if mode == 'file_bytes': i = pick('File'); a = lines[i].split('\t'); a[1] = str(int(a[1]) + 512); lines[i] = '\t'.join(a)
elif mode == 'dir_bytes': i = pick('Directory'); a = lines[i].split('\t'); a[1] = str(int(a[1]) + 512); lines[i] = '\t'.join(a)
elif mode == 'drop_file': del lines[pick('File')]
elif mode == 'extra_node': lines.append('File\t0\t' + root + '/ghost')
elif mode == 'kind_swap': i = pick('File'); a = lines[i].split('\t'); a[0] = 'Symlink'; lines[i] = '\t'.join(a)
elif mode == 'drop_skip': lines = [l for l in lines if not l.startswith('SKIP')]
elif mode == 'extra_skip': lines.append('SKIP\tPermissionDenied\t' + root + '/ghost')
elif mode == 'drop_one_skip':
    k = [i for i, l in enumerate(lines) if l.startswith('SKIP') and '\ufffd' in l]
    if k: del lines[k[0]]
elif mode == 'reason_swap':
    k = [i for i, l in enumerate(lines) if l.startswith('SKIP')]
    if k: a = lines[k[0]].split('\t'); a[1] = 'SeparateVolume'; lines[k[0]] = '\t'.join(a)
elif mode == 'dump_fail': print('\n'.join(lines)); sys.exit(3)
elif mode == 'mutate': open(root + '/drift_new', 'w').write('late')
elif mode == 'none': pass
print('\n'.join(lines))
