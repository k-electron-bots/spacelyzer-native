#!/usr/bin/env python3
"""Old-fail/new-pass regression for Mac run 39832527366 (Apple nm exited non-zero on the lipo'd universal
archive, stderr hidden; cause unproven). The new check reads symbols with LLVM nm (rustup llvm-tools),
per architecture slice. Executed on Linux with the Linux-hosted llvm-nm (set SPZ_LLVM_NM or have the
rustup llvm-tools component installed; this test FAILS if neither exists). Fixtures: HAND-BUILT Mach-O 64
objects in BSD-style archives and a hand-built fat wrapper (not produced by Apple lipo), plus optional
REAL rustc aarch64/x86_64-apple-darwin staticlibs (SPZ_REAL_APPLE_ARCHIVES). Not Apple nm/lipo evidence."""
import os,pathlib,shutil,struct,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parent.parent
old=subprocess.run(['git','show','6a7465427e83b355ba281cfbc5b8bd593423101a:scripts/check-no-ci-symbols.sh'],cwd=repo,stdout=subprocess.PIPE,check=True).stdout

def macho(defined,undefined=(),stab=False,cpu=0x0100000c):
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
    hdr=struct.pack('<IiiIIIII',0xfeedfacf,cpu,3 if cpu==0x01000007 else 0,1,1,24,0,0)
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
        ents+=struct.pack('>iIIII',cpu,3 if cpu==0x01000007 else 0,p+len(datas),len(b),14);datas+=b;
        pad=(-(p+len(datas)))%0x4000;datas+=b'\0'*pad
    head=b'\xca\xfe\xba\xbe'+struct.pack('>I',n)+ents
    return head+b'\0'*(p-len(head))+datas

import sys
nm=os.environ.get('SPZ_LLVM_NM') or ''
if not nm:
 root=subprocess.run(['rustc','--print','sysroot'],stdout=subprocess.PIPE).stdout.decode().strip()
 host=[l.split()[1] for l in subprocess.run(['rustc','-vV'],stdout=subprocess.PIPE).stdout.decode().splitlines() if l.startswith('host:')][0]
 nm=root+'/lib/rustlib/'+host+'/bin/llvm-nm'
assert os.access(nm,os.X_OK),'llvm-nm not available: '+nm
with tempfile.TemporaryDirectory(prefix='sym-check-') as td:
 w=pathlib.Path(td);(w/'bin').mkdir();(w/'scripts').mkdir()
 (w/'old.sh').write_bytes(old)
 for f in ['check-no-ci-symbols.sh','dump-symbols.sh']:shutil.copy(repo/'scripts'/f,w/'scripts')
 stub=w/'bin/nm';stub.write_text('#!/bin/sh\necho "nm: simulated member error" >&2\nexit 1\n');stub.chmod(0o755)
 apple_fails=dict(os.environ,PATH=str(w/'bin')+':'+os.environ['PATH'],SPZ_LLVM_NM=nm,SPZ_EXPECT_ARCHS='arm64 x86_64')
 def envx(**kw):
  e=dict(apple_fails);e.update(kw);return e
 def run(f,env=None,script='scripts/check-no-ci-symbols.sh'):return subprocess.run(['bash',str(w/script),str(w/f)],env=env or apple_fails,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 def sub_(*a):return subprocess.run(list(a),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 X=0x01000007
 def cl(c):return archive([macho(['spz_scan_start','spz_scan_cancel'],['malloc'],cpu=c),macho(['helper'],['spz_scan_start'],stab=True,cpu=c)])
 clean=cl(0x0100000c);clean_x=cl(X)
 files={
  'clean.a':clean,
  'dirty_def.a':archive([macho(['spz_scan_start','spz_ci_scan_gate_release'])]),
  'dirty_ref.a':archive([macho(['spz_scan_start'],['spz_ci_scan_start_parked'])]),   # undefined REFERENCE to a CI symbol must fail too
  'nocontrol.a':archive([macho(['other'],['spz_scan_start'])]),       # control only UNDEFINED
  'badobj.a':archive([macho(['spz_scan_start'])[:60]]),               # truncated member
  'fat_clean.a':fat([(0x0100000c,clean),(X,clean_x)]),
  'fat_x86_lacks_control.a':fat([(0x0100000c,clean),(X,archive([macho(['other'],cpu=X)]))]),
  'fat_x86_dirty.a':fat([(0x0100000c,clean),(X,archive([macho(['spz_scan_start','spz_ci_scan_gate_state'],cpu=X)]))]),
  'fat_arm_only.a':fat([(0x0100000c,clean)]),                         # x86_64 slice missing entirely
  'big.a':archive([macho(['spz_scan_start']+['sym_%06d_padding_to_make_the_name_long_enough_for_pipe_buffers'%i for i in range(30000)])]),
  'empty.a':b'','garbage.a':b'not an archive'}
 for k,v in files.items():(w/k).write_bytes(v)
 # 0. Mach-O thin archive with a single expected arch
 assert run('clean.a',envx(SPZ_EXPECT_ARCHS='arm64')).returncode==0
 # 1. old script fails on a clean artifact when Apple nm fails (reproduces the Mac failure)
 r=run('clean.a',None,'old.sh');assert r.returncode==1 and b'cannot inspect' in r.stderr
 # 2. new script passes clean thin/fat/big and does not depend on the (failing) PATH nm
 for f,e in [('clean.a',envx(SPZ_EXPECT_ARCHS='arm64')),('fat_clean.a',None),('big.a',envx(SPZ_EXPECT_ARCHS='arm64'))]: r=run(f,e);assert r.returncode==0,(f,r.stderr[-300:])
 assert run('clean.a').returncode==1  # thin arm64-only archive where a universal one is required must fail
 # 3. fail-closed cases
 for f in ['dirty_def.a','dirty_ref.a','nocontrol.a','badobj.a','fat_x86_lacks_control.a','fat_x86_dirty.a','fat_arm_only.a','empty.a','garbage.a','absent.a']:
  r=run(f);assert r.returncode==1,(f,r.stdout,r.stderr)
 # 4. tool failure modes are failures with a message, never passes
 r=run('clean.a',envx(SPZ_LLVM_NM=str(w/'nope')));assert r.returncode==1 and b'llvm-nm unavailable' in r.stderr
 bad=w/'badnm.sh';bad.write_text('#!/bin/sh\necho "llvm-nm: boom" >&2\nexit 3\n');bad.chmod(0o755)
 r=run('clean.a',envx(SPZ_LLVM_NM=str(bad)));assert r.returncode==1 and b'boom' in r.stderr
 silent=w/'silentnm.sh';silent.write_text('#!/bin/sh\nexit 0\n');silent.chmod(0o755)
 r=run('clean.a',envx(SPZ_LLVM_NM=str(silent)));assert r.returncode==1 and b'no symbols' in r.stderr
 # 5. thin ELF (Linux fixture, no expected archs) incl. dirty
 for label,src,ok in [('e_clean','void spz_scan_start(void){}',True),('e_dirty','void spz_scan_start(void){}\nvoid spz_ci_scan_gate_release(void){}',False)]:
  (w/f'{label}.c').write_text(src);sub_('cc','-c',str(w/f'{label}.c'),'-o',str(w/f'{label}.o'))
  assert (run(f'{label}.o',envx(SPZ_EXPECT_ARCHS='')).returncode==0)==ok
 # linked executable fixtures (ELF here; a real Mach-O executable fixture is not available offline)
 for label,extra,ok in [('x_clean','',True),('x_dirty','void spz_ci_scan_gate_release(void){}',False)]:
  (w/f'{label}.c').write_text('void spz_scan_start(void){}\n'+extra+'\nint main(void){spz_scan_start();return 0;}\n')
  sub_('cc',str(w/f'{label}.c'),'-o',str(w/label));assert (w/label).exists()
  assert (run(label,envx(SPZ_EXPECT_ARCHS='')).returncode==0)==ok
 # line-format contract: addressed and addressless llvm-nm lines (stub llvm-nm prints fixed text)
 def fixed(text,name):
  f=w/name;f.write_text('#!/bin/sh\ncat <<EOF2\n'+text+'\nEOF2\n');f.chmod(0o755);return str(f)
 (w/'any.a').write_bytes(b'x')
 cases=[('0000000000000000 T _spz_scan_start\n0000000000000010 T _spz_scan_cancel',0),('---------------- T _spz_scan_start',0),('T _spz_scan_start',0),('T spz_scan_start',0),('0000 D _spz_scan_start',0),
  ('                 U _spz_scan_start',1),('0000 t _spz_scan_start',1),('0000 T _spz_scan_start\n                 U _spz_ci_scan_gate_state',1),('T _spz_scan_start\nT _spz_ci_scan_gate_release',1),('0000 T _xspz_scan_start',1),('0000 T _spz_scan_start_extra',1)]
 for text,code in cases:
  r=run('any.a',envx(SPZ_LLVM_NM=fixed(text,'fixednm.sh'),SPZ_EXPECT_ARCHS=''));assert r.returncode==code,(text,r.returncode,r.stderr)
 # CI engine T regex contract, same stub (addressed + addressless), via the real build-ci-engine.sh is covered in test-ci-engine-isolation
 rd=os.environ.get('SPZ_REAL_APPLE_ARCHIVES','')
 if rd and pathlib.Path(rd).is_dir():
  a=pathlib.Path(rd)/'aarch64.a';x=pathlib.Path(rd)/'x86_64.a'
  (w/'real_fat.a').write_bytes(fat([(0x0100000c,a.read_bytes()),(0x01000007,x.read_bytes())]))
  assert run('real_fat.a').returncode==0
  (w/'real_arm_only.a').write_bytes(fat([(0x0100000c,a.read_bytes())]));assert run('real_arm_only.a').returncode==1
  print('PASS real rustc aarch64+x86_64 apple-darwin shipping staticlibs (cross-compiled on Linux; fat wrapper built by this test); missing-slice fails')
 else: print('SKIP real rustc Apple archives (set SPZ_REAL_APPLE_ARCHIVES to a dir with aarch64.a x86_64.a)')
 print('PASS old script fails when Apple nm fails; LLVM-nm per-slice check passes clean thin/fat/30k-symbol tables and fails closed on defined/referenced CI symbol, undefined-only control, truncated member, slice lacking control or dirty, missing slice, empty, garbage, absent file, missing/failing/silent llvm-nm')

# SPZ_DIAG_DIR: dumps are copied for diagnostics on success AND on failure; unset or unwritable never changes the verdict.
def _diag():
    w=pathlib.Path(tempfile.mkdtemp()); good=w/'good.o'
    stub=w/'nm.sh'
    def mk(body):
        stub.write_text('#!/bin/sh\n'+body+'\n'); stub.chmod(0o755)
    for label,body,want in (('ok','echo "---------------- T _spz_scan_start"',0),('nm-fails','echo boom >&2; exit 3',1)):
        mk(body); good.write_bytes(b'x'); d=w/('diag-'+label)
        r=subprocess.run(['bash',str(repo/'scripts/dump-symbols.sh'),str(good),str(w/('o-'+label))],env=dict(os.environ,SPZ_LLVM_NM=str(stub),SPZ_EXPECT_ARCHS='',SPZ_DIAG_DIR=str(d)),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert r.returncode==want,(label,r.returncode,r.stderr)
        files=[p.name for p in d.rglob('*') if p.is_file()]
        assert any(f.endswith('.err') for f in files) and (label!='ok' or 'thin.txt' in files),(label,files)
    r=subprocess.run(['bash',str(repo/'scripts/dump-symbols.sh'),str(good),str(w/'o-bad')],env=dict(os.environ,SPZ_LLVM_NM=str(stub),SPZ_EXPECT_ARCHS='',SPZ_DIAG_DIR='/proc/nope/x'),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    assert r.returncode==1  # unwritable diag dir does not turn a failure into a pass (nm still fails)
    mk('echo "---------------- T _spz_scan_start"')
    r=subprocess.run(['bash',str(repo/'scripts/dump-symbols.sh'),str(good),str(w/'o-ok2')],env=dict(os.environ,SPZ_LLVM_NM=str(stub),SPZ_EXPECT_ARCHS='',SPZ_DIAG_DIR='/proc/nope/x'),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    assert r.returncode==0,r.stderr  # unwritable diag dir does not break a good dump
    print('PASS SPZ_DIAG_DIR copies dumps on success and failure; unwritable dir changes no verdict')
_diag()
