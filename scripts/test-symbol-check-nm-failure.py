#!/usr/bin/env python3
"""Old-fail/new-pass regression for Mac run 39832527366 (nm exited non-zero on the lipo'd universal
archive, stderr hidden). Executed on Linux: stub nm that fails, plus HAND-BUILT Mach-O 64 objects,
BSD-style archives (#1/N names, __.SYMDEF) and a fat wrapper that exercise the Mach-O/fat parser
paths. This is structural parser evidence, NOT Apple nm/lipo/rustc output evidence."""
import os,pathlib,shutil,struct,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parent.parent
old=subprocess.run(['git','show','6a7465427e83b355ba281cfbc5b8bd593423101a:scripts/check-no-ci-symbols.sh'],cwd=repo,stdout=subprocess.PIPE,check=True).stdout

def macho(defined,undefined=(),stab=False):
    names=list(defined)+list(undefined);strtab=b'\0';offs=[]
    for n in names: offs.append(len(strtab));strtab+=('_'+n).encode()+b'\0'
    while len(strtab)%8:strtab+=b'\0'
    nl=b''
    for i,n in enumerate(names):
        t=0x0f if i<len(defined) else 0x01  # N_SECT|N_EXT ; undefined N_EXT
        nl+=struct.pack('<IBBHQ',offs[i],t,1 if i<len(defined) else 0,0,0)
    if stab: nl+=struct.pack('<IBBHQ',1,0x0e|0x20,1,0,0)  # stab (must be ignored)
    symoff=32+24;stroff=symoff+len(nl)
    lc=struct.pack('<IIIIII',2,24,symoff,len(nl)//16,stroff,len(strtab))
    hdr=struct.pack('<IiiIIIII',0xfeedfacf,0x0100000c,0,1,1,24,0,0)
    return hdr+lc+nl+strtab

def member(name,data):
    nm=name.encode()+b'\0'
    while len(nm)%8:nm+=b'\0'
    body=nm+data
    return (b'#1/%-13d'%len(nm)+b'0           0     0     100644  '+b'%-10d'%len(body)+b'`\n'+body)+(b'\n' if len(body)%2 else b'')

def archive(objs):
    sym=member('__.SYMDEF SORTED',struct.pack('<I',0)+struct.pack('<I',4))  # table content is NOT trusted by the parser
    return b'!<arch>\n'+sym+b''.join(member('o%d.o'%i,o) for i,o in enumerate(objs))

def fat(slices):
    n=len(slices);off=8+20*n;hdr=b'\xca\xfe\xba\xbe'+struct.pack('>I',n);body=b''
    for cpu,b in slices:
        off=(off+0x3fff)&~0x3fff
        hdr+=struct.pack('>iIIII',cpu,0,off+len(body)*0,len(b),14);body_off=off
        break
    # simple layout: place slices sequentially at 16k alignment
    out=b'';p=(8+20*n+0x3fff)&~0x3fff;ents=b'';datas=b''
    for cpu,b in slices:
        ents+=struct.pack('>iIIII',cpu,0,p+len(datas),len(b),14);datas+=b;
        pad=(-(p+len(datas)))%0x4000;datas+=b'\0'*pad
    head=b'\xca\xfe\xba\xbe'+struct.pack('>I',n)+ents
    return head+b'\0'*(p-len(head))+datas

with tempfile.TemporaryDirectory(prefix='nm-fail-') as td:
 w=pathlib.Path(td);(w/'bin').mkdir();(w/'scripts').mkdir()
 (w/'old.sh').write_bytes(old)
 for f in ['check-no-ci-symbols.sh','defined-symbols.py']:shutil.copy(repo/'scripts'/f,w/'scripts')
 stub=w/'bin/nm';stub.write_text('#!/bin/sh\necho "nm: simulated member error" >&2\nexit 1\n');stub.chmod(0o755)
 fail=dict(os.environ,PATH=str(w/'bin')+':'+os.environ['PATH']);real=dict(os.environ)
 def run(f,env,script='scripts/check-no-ci-symbols.sh'):return subprocess.run(['bash',str(w/script),str(w/f)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 files={
  'clean.a':archive([macho(['spz_scan_start','spz_scan_cancel'],['malloc']),macho(['helper'],['spz_scan_start'],stab=True)]),
  'dirty_def.a':archive([macho(['spz_scan_start','spz_ci_scan_gate_release'])]),
  'nocontrol.a':archive([macho(['other'],['spz_scan_start'])]),  # control only UNDEFINED -> must fail
  'badobj.a':archive([macho(['spz_scan_start'])[:60]]),          # truncated member
 }
 clean=files['clean.a'];dirty=files['dirty_def.a']
 files['fat_clean.a']=fat([(0x0100000c,clean),(0x01000007,clean)])
 files['fat_one_bad.a']=fat([(0x0100000c,clean),(0x01000007,archive([macho(['other'])]))])  # x86 slice lacks control
 files['fat_dirty.a']=fat([(0x0100000c,clean),(0x01000007,dirty)])
 files['empty.a']=b'';files['garbage.a']=b'not an archive'
 for k,v in files.items():(w/k).write_bytes(v)
 # 1. old script fails when nm fails, even on a clean artifact (the Mac failure)
 r=run('clean.a',fail,'old.sh');assert r.returncode==1 and b'cannot inspect' in r.stderr
 # 2. new script: clean thin + clean fat pass with nm failing, nm error printed
 for f in ['clean.a','fat_clean.a']:
  r=run(f,fail);assert r.returncode==0,(f,r.stderr)
  assert b'nm -g exited 1' in r.stderr and b'simulated member error' in r.stderr
 # 3. fail-closed cases, with failing nm AND with real nm
 for f in ['dirty_def.a','nocontrol.a','badobj.a','fat_one_bad.a','fat_dirty.a','empty.a','garbage.a']:
  for env in (fail,real):
   assert run(f,env).returncode==1,(f,run(f,env).stderr)
 assert run('absent.a',fail).returncode==1
 # 4. parser output: Mach-O underscore stripped, stabs/undefined ignored, per-slice labels
 out=subprocess.run(['python3',str(w/'scripts/defined-symbols.py'),str(w/'fat_clean.a')],stdout=subprocess.PIPE,check=True).stdout.decode()
 assert 'cpu0x100000c spz_scan_start' in out and 'cpu0x1000007 spz_scan_start' in out and 'malloc' not in out and 'helper' in out,out
 print('PASS old script fails on nm failure; parser-based check passes clean thin/fat, prints nm error, fails closed on defined-CI/undefined-control/truncated/missing-slice-control/empty/garbage/absent')
