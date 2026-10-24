#!/usr/bin/env python3
"""Diagnostic capture binding, no fidelity gate integration.
Requires producer ready JSON with step/token/pid/start/executable/source/raw_sha256.
Nothing here manufactures that producer record or changes the raw native state.
"""
import hashlib,json,pathlib,subprocess,time,os,signal,uuid,sys

def digest(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def process_identity(pid):
    def ps(field):
        return subprocess.run(['ps','-p',str(pid),'-o',field+'='],check=True,capture_output=True,text=True,timeout=3).stdout.strip()
    return {'pid':pid,'start':ps('lstart'),'executable':os.path.realpath(ps('comm'))}
def reconcile(raw,probe):
    if raw.get('main')!='true' or raw.get('sheet')!='true' or raw.get('keyIsSheet')!='true' or raw.get('alertModel')!='false':raise ValueError('native sheet/window/alert state refused')
    if int(raw.get('sheetRows','0'))<1:raise ValueError('native content not loaded')
    native=raw.get('sheetId')
    if native not in ['unknown','notscanned']:raise ValueError('positive native identity disagrees')
    if probe.get('identity')!='notscanned' or probe.get('rows',0)<1 or probe.get('complete') is not True or probe.get('source')!='external-AXUIElement':raise ValueError('external identity incomplete/refused')
    return {'nativeIdentity':native,'externalIdentity':probe['identity'],'evidenceRoute':'external-AXUIElement','nativeAccessorPassed':native=='notscanned'}
def capture(*,ready,raw,ack,expected,output,inspect=process_identity,observe=None,screenshot=None,source=None):
    ready,raw,ack,output=map(pathlib.Path,[ready,raw,ack,output])
    if output.exists():raise ValueError('output must be fresh')
    rb=ready.read_bytes();rawbytes=raw.read_bytes();anchor=json.loads(rb)
    keys=['step','token','pid','start','executable','source','raw_sha256']
    if set(anchor)!=set(keys):raise ValueError('malformed producer anchor')
    if not anchor['token'] or len(anchor['token'])<16:raise ValueError('missing/faulty capture token')
    for key in ['step','pid','start','executable','source']:
        if anchor[key]!=expected[key]:raise ValueError('wrong anchor '+key)
    # Caller expected token is the token read from this producer ready publication,
    # retained by the workflow. It cannot be reused after ack or state turnover.
    if anchor['token']!=expected['token']:raise ValueError('wrong token')
    if hashlib.sha256(rawbytes).hexdigest()!=anchor['raw_sha256']:raise ValueError('raw hash mismatch')
    native=dict(x.split('=',1) for x in rawbytes.decode().split() if '=' in x)
    if native.get('step')!=str(anchor['step']):raise ValueError('raw step mismatch')
    if native.get('captureToken')!=anchor['token'] or native.get('pid')!=str(anchor['pid']):raise ValueError('raw process/token mismatch')
    def unchanged():
        if ack.exists() or ready.read_bytes()!=rb or raw.read_bytes()!=rawbytes:raise ValueError('capture handshake changed or acknowledged')
        ident=inspect(anchor['pid'])
        if any(ident[k]!=anchor[k] for k in ['pid','start','executable']):raise ValueError('launched process changed')
        if source()!=anchor['source']:raise ValueError('source changed')
    unchanged()
    probe=observe(anchor) # caller supplies bounded subprocess; exceptions block.
    if any(probe.get('captureToken' if k=='token' else k)!=anchor[k] for k in ['pid','step','token']):raise ValueError('probe anchor mismatch')
    verdict=reconcile(native,probe)
    unchanged()
    output.mkdir()
    (output/'raw-native.txt').write_bytes(rawbytes)
    (output/'external.json').write_text(json.dumps(probe,sort_keys=True))
    screenshot(output/'capture.png')
    if not (output/'capture.png').is_file() or not (output/'capture.png').stat().st_size:raise ValueError('missing screenshot')
    unchanged()
    manifest={'anchor':anchor,'reconciliation':verdict,'image_sha256':digest(output/'capture.png'),'raw_sha256':digest(output/'raw-native.txt')}
    (output/'binding.json').write_text(json.dumps(manifest,sort_keys=True))
    return manifest


def diagnostic_step78(pin_path, raw_path, producer_ready, ack_path, output):
    pin=json.loads(pathlib.Path(pin_path).read_text())
    raw=pathlib.Path(raw_path); native=dict(x.split('=',1) for x in raw.read_text().split() if '=' in x)
    token=pathlib.Path(producer_ready).read_text()
    if native.get('captureToken')!=token or native.get('pid')!=str(pin['pid']) or native.get('source')!=pin['source'] or native.get('step')!='78':raise ValueError('producer ready/raw/pin mismatch')
    # Per-producer-token directory is never reused. Existing output refuses replay.
    root=pathlib.Path(output)/token
    if root.exists():raise ValueError('replayed capture token')
    root.mkdir(parents=True)
    (root/'raw-native.txt').write_bytes(raw.read_bytes())
    (root/'producer-ready.txt').write_bytes(pathlib.Path(producer_ready).read_bytes())
    anchor=dict(pin,step=78,token=token,raw_sha256=digest(raw));(root/'ready.json').write_text(json.dumps(anchor))
    expected=dict(anchor);expected.pop('raw_sha256')
    producer_bytes=pathlib.Path(producer_ready).read_bytes()
    def source():
        if pathlib.Path(producer_ready).read_bytes()!=producer_bytes:raise ValueError('producer ready changed')
        return subprocess.run(['git','rev-parse','HEAD'],check=True,capture_output=True,text=True,timeout=3).stdout.strip()
    def observe(a):
        try:r=subprocess.run(['/tmp/spz-sheet-probe',str(a['pid']),str(a['step']),a['token']],capture_output=True,text=True,timeout=8)
        except subprocess.TimeoutExpired as e:
            def text(v):return v.decode(errors='replace') if isinstance(v,bytes) else (v or '')
            (root/'probe-stdout.txt').write_text(text(e.stdout));(root/'probe-stderr.txt').write_text(text(e.stderr))
            raise
        (root/'probe-stdout.txt').write_text(r.stdout);(root/'probe-stderr.txt').write_text(r.stderr)
        if r.returncode:raise ValueError('external probe refused rc='+str(r.returncode))
        return json.loads(r.stdout)
    def shot(p):subprocess.run(['screencapture','-x',str(p)],check=True,timeout=4)
    return capture(ready=root/'ready.json',raw=raw,ack=ack_path,expected=expected,output=root/'bound',observe=observe,screenshot=shot,source=source)

def wait_pin(pin_path, executable, output, budget=3):
    """Launch PID can appear after open returns. No unbounded launch polling."""
    output=pathlib.Path(output);output.mkdir(parents=True,exist_ok=True)
    deadline=time.monotonic()+budget; reasons=[]
    def remaining():
        n=deadline-time.monotonic()
        if n<=0:raise TimeoutError('launch pin deadline expired')
        return n
    while time.monotonic()<deadline:
        try:
            r=subprocess.run(['pgrep','-n','-f',executable],capture_output=True,text=True,timeout=remaining())
            if r.returncode:raise ValueError('pgrep rc='+str(r.returncode)+' stderr='+r.stderr.strip())
            pid=int(r.stdout.strip());identity={'pid':pid}
            for key,field in [('start','lstart'),('executable','comm')]:
                value=subprocess.run(['ps','-p',str(pid),'-o',field+'='],check=True,capture_output=True,text=True,timeout=remaining()).stdout.strip()
                identity[key]=os.path.realpath(value) if key=='executable' else value
            if not identity['start'] or identity['executable']!=os.path.realpath(executable):raise ValueError('unexpected launched process identity '+json.dumps(identity))
            identity['source']=subprocess.run(['git','rev-parse','HEAD'],check=True,capture_output=True,text=True,timeout=remaining()).stdout.strip()
            pathlib.Path(pin_path).write_text(json.dumps(identity))
            (output/'launch-pin.json').write_text(json.dumps(identity))
            print('EXTERNAL DIAGNOSTIC launch pin '+json.dumps(identity),flush=True)
            return identity
        except Exception as e:reasons.append(type(e).__name__+': '+str(e))
        time.sleep(min(.1,max(0,deadline-time.monotonic())))
    reason={'status':'refused','budgetSeconds':budget,'reasons':reasons}
    (output/'launch-pin-failure.json').write_text(json.dumps(reason))
    print('EXTERNAL DIAGNOSTIC launch pin refused '+json.dumps(reason),flush=True)
    raise ValueError('bounded launch pin unavailable')

def supervise_capture(args, budget=18, command=None):
    """Parent retains status and partial files even if capture worker is killed.
    Kill the entire worker process group, including a blocked AX/screenshot child.
    This cap is below the existing 30s producer ack wait, not an acceptance gate.
    """
    output=pathlib.Path(args[-1]);output.mkdir(parents=True,exist_ok=True)
    attempt=output/('attempt-'+uuid.uuid4().hex);attempt.mkdir()
    status={'status':'incomplete','budgetSeconds':budget,'acceptance':False}
    manifest=attempt/'supervisor.json';manifest.write_text(json.dumps(status))
    argv=command or [sys.executable,__file__,'capture-worker',*map(str,args)]
    with (attempt/'worker-stdout.txt').open('w') as out, (attempt/'worker-stderr.txt').open('w') as err:
        proc=None
        try:
            proc=subprocess.Popen(argv,stdout=out,stderr=err,start_new_session=True)
            rc=proc.wait(timeout=budget)
            status.update(status='complete' if rc==0 else 'failed',returncode=rc)
        except subprocess.TimeoutExpired:
            status.update(status='timed-out',reason='outer capture deadline expired; partial artifacts retained')
        except Exception as e:status.update(status='failed',reason=type(e).__name__+': '+str(e))
        finally:
            if proc is not None:
                # Clean descendants after worker exit as well as after a timeout.
                try:os.killpg(proc.pid,signal.SIGKILL)
                except ProcessLookupError:pass
                proc.wait()
            manifest.write_text(json.dumps(status,sort_keys=True))
    print('EXTERNAL DIAGNOSTIC supervisor '+manifest.read_text(),flush=True)
    if status['status']=='complete':print((attempt/'worker-stdout.txt').read_text(),flush=True)
    return 0 if status['status']=='complete' else 1

if __name__=='__main__':
    import sys
    if len(sys.argv)==5 and sys.argv[1]=='wait-pin':
        wait_pin(*sys.argv[2:])
    elif len(sys.argv)==7 and sys.argv[1]=='capture':
        sys.exit(supervise_capture(sys.argv[2:]))
    elif len(sys.argv)==7 and sys.argv[1]=='capture-worker':
        try:print('EXTERNAL DIAGNOSTIC binding '+json.dumps(diagnostic_step78(*sys.argv[2:]),sort_keys=True),flush=True)
        except Exception as e:
            pathlib.Path(sys.argv[6]).mkdir(parents=True,exist_ok=True)
            (pathlib.Path(sys.argv[6])/'diagnostic-failure.txt').write_text(type(e).__name__+': '+str(e))
            raise
    else:raise SystemExit('usage: wait-pin PIN EXECUTABLE OUTPUT | capture PIN RAW READY ACK OUTPUT')
