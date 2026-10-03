#!/usr/bin/env python3
"""One bounded CI capture. Missing schema/readiness/alignment is inconclusive."""
import ctypes, datetime, json, os, pathlib, select, signal, subprocess, sys, time, zipfile
import xml.etree.ElementTree as ET
ROOT = pathlib.Path('/tmp/spz-chronology')
ROOT.mkdir(exist_ok=True)
ACK = pathlib.Path('/tmp/spz-cold-click-ack')
READY = pathlib.Path('/tmp/spz-cold-click-ready')
status = {'outcome': 'INCONCLUSIVE', 'limits': 'CPU samples only; absence does not prove sleep/block/scheduler cause. No clean benchmark.20s need not cover all40 arrows; actual phase alignment/full stack/thread identity require inspection. Size limits are post-generation artifact limits, not live storage bounds.'}
proc = None
lib = None
token = ctypes.c_int(-1)
notify_fd = ctypes.c_int(-1)
def bridge():
    before = time.time_ns(); uptime = time.monotonic_ns(); after = time.time_ns()
    return {'wall_before_unix_ns': before, 'uptime_ns': uptime, 'wall_after_unix_ns': after}
def save():
    (ROOT / 'status.json').write_text(json.dumps(status, indent=2))
def ack():
    try: save()
    finally: ACK.touch()
def command(args, filename, timeout):
    with (ROOT / filename).open('w') as out:
        return subprocess.run(args, stdout=out, stderr=subprocess.STDOUT, timeout=timeout).returncode
def stop():
    if proc is not None and proc.poll() is None:
        proc.send_signal(signal.SIGINT)
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)
try:
    pid = int(READY.read_text().strip())
    if pid <= 0: raise RuntimeError("invalid app PID")
    os.kill(pid, 0)
    status.update(pid=pid, setup_bridge=bridge())
    checks = [('help-record.txt', ['xcrun','xctrace','help','record']),
              ('help-export.txt', ['xcrun','xctrace','help','export']),
              ('templates.txt', ['xcrun','xctrace','list','templates'])]
    for filename, cmd in checks:
        code = command(cmd, filename, 10)
        status[filename] = code
        if code != 0: raise RuntimeError(f'contract discovery failed: {filename} exit={code}')
    record_help = (ROOT/'help-record.txt').read_text()
    export_help = (ROOT/'help-export.txt').read_text()
    templates = (ROOT/'templates.txt').read_text()
    required = ['--attach','--time-limit','--output','--template','--notify-tracing-started','--no-prompt']
    if any(flag not in record_help for flag in required) or any(flag not in export_help for flag in ['--input','--toc','--xpath','--output']) or 'Time Profiler' not in templates:
        raise RuntimeError('installed xctrace contract/template not verified')
    # Register before starting capture: the notification is recording readiness, not process launch.
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    lib.notify_register_file_descriptor.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int), ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
    lib.notify_register_file_descriptor.restype = ctypes.c_uint32
    lib.notify_cancel.argtypes = [ctypes.c_int]
    lib.notify_cancel.restype = ctypes.c_uint32
    name = f'com.spacelyzer.ci.chronology.{pid}.{os.getpid()}'
    if lib.notify_register_file_descriptor(name.encode(), ctypes.byref(notify_fd), 0, ctypes.byref(token)) != 0:
        raise RuntimeError('notification file-descriptor register failed')
    trace = ROOT/'interactions.trace'
    args = ['xcrun','xctrace','record','--template','Time Profiler','--attach',str(pid),
            '--time-limit','20s','--output',str(trace),'--no-prompt','--notify-tracing-started',name]
    status.update(command=args, prelaunch_bridge=bridge(), notification=name)
    with (ROOT/'record-command.txt').open('w') as out:
        proc = subprocess.Popen(args, stdout=out, stderr=subprocess.STDOUT)
        deadline = time.monotonic()+12
        started = False
        while time.monotonic()<deadline and proc.poll() is None:
            readable, _, _ = select.select([notify_fd.value], [], [], .02)
            if readable:
                delivered = os.read(notify_fd.value, 4)
                if len(delivered) != 4: raise RuntimeError('short notification token delivery')
                delivered_token = int.from_bytes(delivered, 'big', signed=False)
                status.update(notification_token_bytes_hex=delivered.hex(), registered_token=token.value, delivered_token=delivered_token)
                if delivered_token != token.value: raise RuntimeError('notification token mismatch')
                started = True; break
        if not started:
            raise RuntimeError('capture readiness missing or process exited; no input coverage claim')
        status.update(recording_started_bridge=bridge(), readiness='DARWIN_TRACING_STARTED_FD_NOTIFICATION-TRACE-METADATA-STILL-REQUIRED', outcome='RECORDING-REQUIRES-ALIGNMENT')
        ack()
        try: code = proc.wait(timeout=35)
        except subprocess.TimeoutExpired: raise RuntimeError('capture process timeout')
    status.update(record_exit=code, record_end_bridge=bridge())
    if code != 0 or not trace.is_dir(): raise RuntimeError('capture failed or trace missing')
    size = sum(p.stat().st_size for p in trace.rglob('*') if p.is_file())
    status['raw_trace_bytes']=size
    if size > 128*1024*1024: raise RuntimeError('raw trace exceeds128MiB; no export/alignment claim')
    with zipfile.ZipFile(ROOT/'raw-trace.zip','w',zipfile.ZIP_DEFLATED) as z:
        for p in trace.rglob('*'):
            if p.is_file(): z.write(p, str(p.relative_to(ROOT)))
    if command(['xcrun','xctrace','export','--input',str(trace),'--toc','--output',str(ROOT/'toc.xml')], 'toc-command.txt',30) != 0:
        raise RuntimeError('TOC export failed')
    toc = ET.parse(ROOT/'toc.xml').getroot()
    tables = toc.findall('.//run/data/table')
    observed = [t.attrib.get('schema') for t in tables]
    status['observed_schemas']=observed
    candidates = [v for v in ['time-profile','time-sample'] if v in observed]
    if not candidates: raise RuntimeError('no observed chronology table; do not guess schema')
    # Export only an actually observed table, retaining its raw references and metadata.
    schema = candidates[0]
    runs = [r for r in toc.findall('.//run') if any(t.attrib.get('schema')==schema for t in r.findall('./data/table'))]
    if len(runs)!=1 or not runs[0].attrib.get('number','').isdigit():
        raise RuntimeError('ambiguous trace run; no export/alignment claim')
    run = runs[0].attrib['number']
    xpath = f'/trace-toc/run[@number="{run}"]/data/table[@schema="{schema}"]'
    code = command(['xcrun','xctrace','export','--input',str(trace),'--xpath',xpath,'--output',str(ROOT/'samples.xml')], 'samples-command.txt',60)
    status.update(schema=schema, xpath=xpath, export_exit=code)
    if code != 0: raise RuntimeError('sample table export failed')
    if (ROOT/'samples.xml').stat().st_size >64*1024*1024:
        (ROOT/'samples.xml').unlink(); raise RuntimeError('export exceeds64MiB; raw trace retained, table omitted')
    status['outcome']='CAPTURED-UNVERIFIED-CHRONOLOGY'
    status['required_review']='Resolve exact PID/main thread, run start and sample-time units, ref IDs/full stacks and phase bridge overlap. Missing/ambiguous evidence remains inconclusive.'
except Exception as error:
    status.update(outcome='INCONCLUSIVE', error=str(error)); stop()
finally:
    # notify_cancel owns/ closes its registered descriptor. Never close it again.
    # Cleanup failures are evidence, but must not suppress status/handshake release.
    try:
        if lib is not None and token.value >= 0:
            cancelled = lib.notify_cancel(token.value)
            status['notification_cancel_status'] = cancelled
            if cancelled != 0:
                status.update(outcome='INCONCLUSIVE', cleanup_error='notification cancel failed; descriptor ownership unresolved')
            token.value = -1
            notify_fd.value = -1
    except Exception as error:
        status.update(outcome='INCONCLUSIVE', cleanup_error=str(error))
    finally:
        status['cleanup_bridge'] = bridge()
        try: save()
        finally: ACK.touch()
