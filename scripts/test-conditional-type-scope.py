#!/usr/bin/env python3
"""Conservative nominal-type conditional availability check, not full Swift typechecking.
Generate declarations/references from real Swift sources; retain every #if directive.
Compiler resolves the generated model in shipping and CI modes. API bodies are NOT
compiled by this model. Duplicate nested names are excluded and listed, never silently
represented as unique. Comment/string masking is lexical, not a Swift semantic parser.
"""
import pathlib,re,subprocess,tempfile,os,sys,collections
ROOT=pathlib.Path(__file__).resolve().parent.parent
# Mask comments/strings while preserving newlines. Swift raw-string delimiters and
# multiline strings handled. String interpolation contents intentionally excluded:
# this gate covers code-token type references, NOT references inside interpolation.
def mask(s):
 out=list(s);i=0;n=len(s)
 def blank(a,b):
  for k in range(a,b):
   if s[k]!='\n':out[k]=' '
 while i<n:
  a=i
  if s.startswith('//',i):
   j=s.find('\n',i);i=n if j<0 else j;blank(a,i)
  elif s.startswith('/*',i):
   i+=2;depth=1
   while i<n and depth:
    if s.startswith('/*',i):depth+=1;i+=2
    elif s.startswith('*/',i):depth-=1;i+=2
    else:i+=1
   if depth:raise ValueError('unterminated block comment')
   blank(a,i)
  else:
   m=re.match(r'(#+)?("""|")',s[i:])
   if not m:i+=1;continue
   hashes=m[1] or '';q=m[2];i+=len(m[0]);end=q+hashes
   while i<n:
    if s.startswith('\\'+hashes,i):i+=len(hashes)+2;continue
    if s.startswith(end,i):i+=len(end);break
    i+=1
   else:raise ValueError('unterminated string')
   blank(a,i)
 return ''.join(out)
def model(files):
 data={p:mask(t) for p,t in files.items()};decls=collections.defaultdict(list)
 for p,t in data.items():
  for m in re.finditer(r'\b(?:class|struct|enum|actor|protocol)\s+([A-Za-z_]\w*)',t):decls[m[1]].append((p,m.start(1)))
 excluded=sorted(k for k,v in decls.items() if len(v)!=1 or k=='Result') # Swift.Result collision: nested same-name model excluded explicitly
 names=set(decls)-set(excluded);parts=[];refs=0
 for p,t in data.items():
  original=files[p].splitlines();offset=0;depth=0
  for lineno,line in enumerate(t.splitlines(),1):
   directive=re.match(r'\s*#(if|elseif|else|endif)\b',line)
   if directive:
    kind=directive[1]
    if kind=='if':depth+=1
    elif kind=='endif':depth-=1
    elif depth<1:raise ValueError('unmatched branch')
    if depth<0:raise ValueError('unmatched endif')
    parts.append(original[lineno-1].split('//')[0]);offset+=len(line)+1;continue
   if re.match(r'\s*#',line):raise ValueError('unsupported directive '+p+':'+str(lineno))
   for m in re.finditer(r'\b[A-Za-z_]\w*\b',line):
    name=m[0]
    if name not in names:continue
    if (p,offset+m.start())==decls[name][0]:parts.append('enum Scope_'+name+' {}')
    else:
     refs+=1;parts.append('func scopeReference'+str(refs)+'(){ _ = '+'Scope_'+name+'.self }')
   offset+=len(line)+1
  if depth:raise ValueError('unterminated conditional '+p)
 return '\n'.join(parts),excluded,refs
# Lexer/parser controls: comments/literals do not create declarations; unsupported
# directives and malformed nesting refuse instead of silently skipping a branch.
probe='// enum Fake {}\n/* struct Fake2 {} /* nested */ */\nlet a = #"enum Fake3 {}"#\nlet b = """enum Fake4 {}"""\nenum Real {}\n'
assert set(re.findall(r'\benum\s+(\w+)',mask(probe)))=={'Real'}
for bad in ['#if FLAG\nenum Broken {}', '#else\nenum Broken {}', '#unsupported thing']:
 try:model({'probe.swift':bad})
 except ValueError:pass
 else:raise AssertionError('unsupported/malformed source accepted')
print('PASS lexical controls + unsupported/malformed directives fail closed')
files={str(p.relative_to(ROOT)):p.read_text() for p in sorted((ROOT/'Sources/Spacelyzer').glob('*.swift'))}
old=dict(files);oldpath='Sources/Spacelyzer/SpacelyzerApp.swift'
old[oldpath]=subprocess.run(['git','show','b1ce2312d0e4cfe9723a86453d41b9bfe37157b7:'+oldpath],cwd=ROOT,capture_output=True,text=True,check=True).stdout
swift=pathlib.Path(os.environ.get('SWIFT_BIN','/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin'))/'swiftc'
with tempfile.TemporaryDirectory() as d:
 for label,source in [('old',old),('fixed',files),('mutation',dict(files,**{'scope-mutation.swift':'#if SPZ_CI_TESTS\nenum NewlyAddedObserver {}\n#endif\nfunc leaked() { _ = NewlyAddedObserver.self }\n'}))]:
  text,excluded,refs=model(source);p=pathlib.Path(d)/(label+'.swift');p.write_text(text)
  print(label,'mechanical nominal model refs='+str(refs),'UNCOVERED ambiguous/nested names='+','.join(excluded))
  for mode,flags in [('shipping',[]),('CI',['-D','SPZ_CI_TESTS']),('CI-perf-shots',['-D','SPZ_CI_TESTS','-D','SPZ_CI_PERF','-D','SPZ_CI_SHOTS'])]:
   r=subprocess.run([str(swift),'-typecheck',*flags,str(p)],capture_output=True,text=True)
   if label in ['old','mutation'] and mode=='shipping':
    assert r.returncode!=0 and ('Scope_FooterAXEvidence' if label=='old' else 'Scope_NewlyAddedObserver') in r.stderr,r.stderr
   else:assert r.returncode==0,(label,mode,r.stderr)
   print('PASS',label,mode,'broken rejected' if r.returncode else 'model typechecks')
print('COVERAGE: mechanically derived unique nominal code-token availability across real source #if nesting; shipping/CI/optional flags')
print('NOT COVERED: native SDK/API/member/type/actor semantics, duplicate nested names, interpolation-only references, runtime or pixels')
