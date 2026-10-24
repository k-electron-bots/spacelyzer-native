#!/usr/bin/env python3
"""Capture binding. External observed-identity gate is separately named.
Requires producer ready JSON with step/token/pid/start/executable/source/raw_sha256.
Nothing here manufactures that producer record or changes the raw native state.
"""
import hashlib,json,pathlib,subprocess,time,os,signal,uuid,sys,re,shutil

def digest(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def process_identity(pid):
    def ps(field):
        return subprocess.run(['ps','-p',str(pid),'-o',field+'='],check=True,capture_output=True,text=True,timeout=3).stdout.strip()
    return {'pid':pid,'start':ps('lstart'),'executable':os.path.realpath(ps('comm'))}
def validate_probe(probe):
    # Re-read observed content, never accept a classifier/summary flag alone.
    texts=probe.get('texts')
    if not isinstance(texts,list) or not all(isinstance(t,str) for t in texts):raise ValueError('missing observed text')
    if 'Not scanned' not in texts or 'These locations were not scanned, so they are not in the totals.' not in texts:raise ValueError('missing exact observed identity text')
    if any(t.startswith('Moved ') and 'to the Trash.' in t for t in texts):raise ValueError('conflicting observed removal identity')
    if type(probe.get('rows')) is not int or probe['rows']<1:raise ValueError('missing loaded AX rows')
    if probe.get('scopeCount')!=1 or probe.get('reason')!='observed':raise ValueError('incomplete/ambiguous external scope')
    if probe.get('identity')!='notscanned' or probe.get('complete') is not True or probe.get('source')!='external-AXUIElement':raise ValueError('external identity incomplete/refused')

def reconcile(raw,probe):
    if raw.get('main')!='true' or raw.get('sheet')!='true' or raw.get('keyIsSheet')!='true' or raw.get('alertModel')!='false':raise ValueError('native sheet/window/alert state refused')
    if int(raw.get('sheetRows','0'))<1:raise ValueError('native content not loaded')
    native=raw.get('sheetId')
    if native not in ['unknown','notscanned']:raise ValueError('positive native identity disagrees')
    validate_probe(probe)
    return {'nativeIdentity':native,'externalIdentity':probe['identity'],'evidenceRoute':'external-AXUIElement','nativeAccessorPassed':native=='notscanned'}
def probe_request_path(ack):
    ack=pathlib.Path(ack);return ack.with_name(ack.name.replace('ack','probe',1))
BLOCKED_WAIT_SECONDS=3.0
def blocked_path(ack):
    ack=pathlib.Path(ack);return ack.with_name(ack.name.replace('ack','blocked',1))
def drift_path(ack):
    ack=pathlib.Path(ack);return ack.with_name(ack.name.replace('ack','drift',1))
def capture(*,ready,raw,ack,expected,output,inspect=process_identity,observe=None,screenshot=None,source=None):
    ready,raw,ack,output=map(pathlib.Path,[ready,raw,ack,output])
    if output.exists():raise ValueError('output must be fresh')
    rb=ready.read_bytes();rawbytes=raw.read_bytes();anchor=json.loads(rb)
    keys=['step','token','pid','start','executable','source','raw_sha256']
    if set(anchor)!=set(keys):raise ValueError('malformed producer anchor')
    if not isinstance(anchor['token'],str) or not re.fullmatch(r'[A-Za-z0-9-]{16,80}',anchor['token']):raise ValueError('missing/faulty capture token')
    for key in ['step','pid','start','executable','source']:
        if anchor[key]!=expected[key]:raise ValueError('wrong anchor '+key)
    # Caller expected token is the token read from this producer ready publication,
    # retained by the workflow. It cannot be reused after ack or state turnover.
    if anchor['token']!=expected['token']:raise ValueError('wrong token')
    if hashlib.sha256(rawbytes).hexdigest()!=anchor['raw_sha256']:raise ValueError('raw hash mismatch')
    native=dict(x.split('=',1) for x in rawbytes.decode().split() if '=' in x)
    if native.get('step')!=str(anchor['step']):raise ValueError('raw step mismatch')
    if native.get('captureToken')!=anchor['token'] or native.get('pid')!=str(anchor['pid']):raise ValueError('raw process/token mismatch')
    observations=[]
    def unchanged(phase):
        if ack.exists() or ready.read_bytes()!=rb or raw.read_bytes()!=rawbytes:raise ValueError('capture handshake changed or acknowledged')
        if drift_path(ack).exists():raise ValueError('live app state drifted during external observation')
        ident=inspect(anchor['pid'])
        if any(ident[k]!=anchor[k] for k in ['pid','start','executable']):raise ValueError('launched process changed')
        actual_source=source()
        if actual_source!=anchor['source']:raise ValueError('source changed')
        observations.append(dict(phase=phase,process=ident,source=actual_source,raw_sha256=digest(raw),ready_sha256=digest(ready),ack=False,monotonic=time.monotonic()))
    unchanged('before-probe')
    probe=observe(anchor) # caller supplies bounded subprocess; exceptions block.
    if any(probe.get('captureToken' if k=='token' else k)!=anchor[k] for k in ['pid','step','token']):raise ValueError('probe anchor mismatch')
    verdict=reconcile(native,probe)
    unchanged('after-probe')
    output.mkdir()
    (output/'raw-native.txt').write_bytes(rawbytes)
    (output/'external.json').write_text(json.dumps(probe,sort_keys=True))
    screenshot(output/'capture.png')
    if not (output/'capture.png').is_file() or not (output/'capture.png').stat().st_size:raise ValueError('missing screenshot')
    unchanged('after-image')
    manifest={'anchor':anchor,'reconciliation':verdict,'image_sha256':digest(output/'capture.png'),'raw_sha256':digest(output/'raw-native.txt'),'external_sha256':digest(output/'external.json'),'observations':observations}
    (output/'binding.json').write_text(json.dumps(manifest,sort_keys=True))
    return manifest


def diagnostic_step78(pin_path, raw_path, producer_ready, ack_path, output):
    pin=json.loads(pathlib.Path(pin_path).read_text())
    raw=pathlib.Path(raw_path); native=dict(x.split('=',1) for x in raw.read_text().split() if '=' in x)
    token=pathlib.Path(producer_ready).read_text()
    if native.get('captureToken')!=token or native.get('pid')!=str(pin['pid']) or native.get('source')!=pin['source'] or native.get('step')!='78':raise ValueError('producer ready/raw/pin mismatch')
    # Per-producer-token directory is never reused. Existing output refuses replay.
    if not re.fullmatch(r'[A-Za-z0-9-]{16,80}',token):raise ValueError('unsafe producer token')
    root=pathlib.Path(output)/token
    if root.exists():raise ValueError('replayed capture token')
    root.mkdir(parents=True)
    (root/'raw-native.txt').write_bytes(raw.read_bytes())
    (root/'producer-ready.txt').write_bytes(pathlib.Path(producer_ready).read_bytes())
    (root/'process-pin.json').write_text(json.dumps(pin))
    anchor=dict(pin,step=78,token=token,raw_sha256=digest(raw));(root/'ready.json').write_text(json.dumps(anchor))
    expected=dict(anchor);expected.pop('raw_sha256')
    producer_bytes=pathlib.Path(producer_ready).read_bytes()
    def source():
        if pathlib.Path(producer_ready).read_bytes()!=producer_bytes:raise ValueError('producer ready changed')
        return subprocess.run(['git','rev-parse','HEAD'],check=True,capture_output=True,text=True,timeout=3).stdout.strip()
    def observe(a):
        # The app only serves its run loop (needed for out-of-process AX) while this
        # request file exists, and records live-state drift in the drift file.
        req=probe_request_path(ack_path);req.write_text(a['token'])
        try:result=observe_inner(a)
        finally:req.unlink(missing_ok=True)
        # The app writes the blocked marker only after its last live comparison, once
        # it is back in the blocking wait. No image or after-probe check proceeds
        # without it, so a final run-loop slice cannot race the screenshot.
        marker=blocked_path(ack_path);end=time.monotonic()+BLOCKED_WAIT_SECONDS
        while not marker.exists():
            if time.monotonic()>=end:raise ValueError('app did not confirm returning to the blocked wait')
            time.sleep(0.02)
        return result
    def observe_inner(a):
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

def verify_observed_evidence(raw_path, producer_ready, pin_path, output, expected_source, expected_executable, canonical_image=None):
    """Offline artifact validation, not a second live AX/process observation.
    Trusted pins are caller inputs from the current workflow, not manifest flags.
    Only complete binding-worker evidence from the unique successful supervisor
    can establish the separately named external observed criterion.
    """
    raw_path,producer_ready,pin_path,output=map(pathlib.Path,[raw_path,producer_ready,pin_path,output])
    rawbytes=raw_path.read_bytes();native=dict(x.split('=',1) for x in rawbytes.decode().split() if '=' in x)
    token=producer_ready.read_text()
    if not re.fullmatch(r'[A-Za-z0-9-]{16,80}',token):raise ValueError('unsafe producer token')
    pin=json.loads(pin_path.read_text())
    if pin.get('source')!=expected_source or pin.get('executable')!=os.path.realpath(expected_executable) or type(pin.get('pid')) is not int or pin['pid']<=0 or not pin.get('start'):raise ValueError('workflow process/source pin mismatch')
    root=output/token;bound=root/'bound'
    if json.loads((root/'process-pin.json').read_text())!=pin or json.loads((output/'launch-pin.json').read_text())!=pin:raise ValueError('pin copies disagree')
    if (root/'producer-ready.txt').read_bytes()!=producer_ready.read_bytes():raise ValueError('producer publication mismatch')
    if (root/'raw-native.txt').read_bytes()!=rawbytes or (bound/'raw-native.txt').read_bytes()!=rawbytes:raise ValueError('raw copies disagree')
    anchor=json.loads((root/'ready.json').read_text())
    expected=dict(pin,step=78,token=token,raw_sha256=hashlib.sha256(rawbytes).hexdigest())
    if anchor!=expected:raise ValueError('anchor does not match workflow pin/raw/producer')
    if any(native.get(k)!=str(v) for k,v in dict(step=78,captureToken=token,pid=pin['pid'],source=expected_source).items()):raise ValueError('raw anchor mismatch')
    attempts=list(output.glob('attempt-*/supervisor.json'))
    if len(attempts)!=1:raise ValueError('missing/repeated supervisor attempt')
    supervisor=json.loads(attempts[0].read_text())
    if supervisor.get('status')!='complete' or supervisor.get('returncode')!=0 or supervisor.get('budgetSeconds')!=18:raise ValueError('incomplete supervisor')
    if (output/'diagnostic-failure.txt').exists():raise ValueError('worker failure retained')
    manifest=json.loads((bound/'binding.json').read_text())
    if manifest.get('anchor')!=expected:raise ValueError('manifest anchor mismatch')
    for name,field in [('raw-native.txt','raw_sha256'),('external.json','external_sha256'),('capture.png','image_sha256')]:
        if not (bound/name).stat().st_size or digest(bound/name)!=manifest.get(field):raise ValueError('missing/tampered '+name)
    if manifest['raw_sha256']!=expected['raw_sha256']:raise ValueError('bound raw hash mismatch')
    probe=json.loads((bound/'external.json').read_text())
    if any(probe.get(k)!=v for k,v in dict(pid=pin['pid'],step=78,captureToken=token).items()):raise ValueError('external anchor mismatch')
    verdict=reconcile(native,probe)
    if manifest.get('reconciliation')!=verdict:raise ValueError('summary disagrees with observed bytes')
    checks=manifest.get('observations')
    if not isinstance(checks,list) or len(checks)!=3:raise ValueError('missing pre/post observations')
    previous=-1
    for obs,phase in zip(checks,['before-probe','after-probe','after-image']):
        if obs.get('phase')!=phase or obs.get('process')!={k:pin[k] for k in ['pid','start','executable']} or obs.get('source')!=expected_source or obs.get('ack') is not False or obs.get('raw_sha256')!=expected['raw_sha256'] or obs.get('ready_sha256')!=digest(root/'ready.json'):raise ValueError('pre/post observation mismatch')
        stamp=obs.get('monotonic')
        if type(stamp) not in [int,float] or not __import__('math').isfinite(stamp) or stamp<previous:raise ValueError('invalid observation chronology')
        previous=stamp
    if checks[-1]['monotonic']-checks[0]['monotonic']>18:raise ValueError('capture binding exceeded deadline')
    if canonical_image is not None and digest(canonical_image)!=manifest['image_sha256']:raise ValueError('accepted image differs from bound capture')
    return dict(verdict,image=str(bound/'capture.png'),image_sha256=manifest['image_sha256'],criterion='observed-sheet-v1')

if __name__=='__main__':
    import sys
    if len(sys.argv)==5 and sys.argv[1]=='wait-pin':
        wait_pin(*sys.argv[2:])
    elif len(sys.argv)==9 and sys.argv[1]=='install-image':
        result=verify_observed_evidence(*sys.argv[2:8])
        shutil.copyfile(result['image'],sys.argv[8])
        print('OBSERVED SHEET IMAGE '+json.dumps(result,sort_keys=True))
    elif len(sys.argv)==7 and sys.argv[1]=='capture':
        sys.exit(supervise_capture(sys.argv[2:]))
    elif len(sys.argv)==7 and sys.argv[1]=='capture-worker':
        try:print('EXTERNAL DIAGNOSTIC binding '+json.dumps(diagnostic_step78(*sys.argv[2:]),sort_keys=True),flush=True)
        except Exception as e:
            pathlib.Path(sys.argv[6]).mkdir(parents=True,exist_ok=True)
            (pathlib.Path(sys.argv[6])/'diagnostic-failure.txt').write_text(type(e).__name__+': '+str(e))
            raise
    else:raise SystemExit('usage: wait-pin PIN EXECUTABLE OUTPUT | capture PIN RAW READY ACK OUTPUT')
