#!/usr/bin/env python3
"""Executed Linux control for CaptureAckWait with injected file/time/pump hooks.
Proves the wait logic only; NOT AX servicing, AppKit or native behavior."""
import os,pathlib,subprocess,tempfile
src=pathlib.Path('Sources/Spacelyzer/CaptureAckWait.swift').read_text()
swift=pathlib.Path(os.environ.get('SWIFT_BIN','/tmp/swift-6.1.2-RELEASE-ubuntu22.04/usr/bin'))/'swiftc'
main='''
import Foundation
var files=Set<String>(); var writes=[String:String](); var t=Date(timeIntervalSince1970:0); var log=[String]()
var fp="a"; var pumps=0; var sleeps=0
func hooks(onPump:@escaping()->Void={}, onSleep:@escaping()->Void={})->CaptureAckWait.Hooks {
 CaptureAckWait.Hooks(exists:{files.contains($0)}, write:{writes[$0]=$1; files.insert($0)}, now:{t},
  sleep:{ _ in sleeps+=1; t=t.addingTimeInterval(0.05); onSleep() }, pump:{ _ in pumps+=1; t=t.addingTimeInterval(0.05); onPump() })
}
func reset(){files=[];writes=[:];t=Date(timeIntervalSince1970:0);fp="a";pumps=0;sleeps=0}
let scenario=CommandLine.arguments[1]
let dl=Date(timeIntervalSince1970:1)
switch scenario {
case "block-without-probe": // no request file: never pumps, same as the original loop
 reset(); let r=CaptureAckWait.wait(step:78,deadline:dl,fingerprint:{fp},hooks:hooks(onSleep:{ if sleeps==3 {files.insert("/tmp/spz-demo-ack-78")} }))
 print(r,pumps,sleeps,writes.count); exit(r && pumps==0 && sleeps==3 && writes.isEmpty ? 0:1)
case "probe-pumps-no-drift":
 reset(); files.insert("/tmp/spz-demo-probe-78")
 let r=CaptureAckWait.wait(step:78,deadline:dl,fingerprint:{fp},hooks:hooks(onPump:{ if pumps==4 {files.insert("/tmp/spz-demo-ack-78")} }))
 print(r,pumps,sleeps,writes.count); exit(r && pumps==4 && sleeps==0 && writes.isEmpty ? 0:1)
case "probe-drift-recorded-once":
 reset(); files.insert("/tmp/spz-demo-probe-78")
 let r=CaptureAckWait.wait(step:78,deadline:dl,fingerprint:{fp},hooks:hooks(onPump:{ if pumps==2 {fp="b"}; if pumps==3 {fp="c"}; if pumps==5 {files.insert("/tmp/spz-demo-ack-78")} }))
 let d=writes["/tmp/spz-demo-drift-78"] ?? ""
 print(r,d); exit(r && writes.count==1 && d.contains("baseline=a") && d.contains("current=b") ? 0:1)
case "probe-removed-returns-to-block":
 reset(); files.insert("/tmp/spz-demo-probe-78")
 let r=CaptureAckWait.wait(step:78,deadline:dl,fingerprint:{fp},hooks:hooks(onPump:{ if pumps==2 {files.remove("/tmp/spz-demo-probe-78")} }, onSleep:{ if sleeps==2 {files.insert("/tmp/spz-demo-ack-78")} }))
 print(r,pumps,sleeps,writes); exit(r && pumps==2 && sleeps==2 && writes["/tmp/spz-demo-blocked-78"]=="stable" && writes.count==1 ? 0:1)
case "blocked-marker-after-last-check-catches-late-drift":
 reset(); files.insert("/tmp/spz-demo-probe-78")
 var removedAt=0
 let r=CaptureAckWait.wait(step:78,deadline:dl,fingerprint:{fp},hooks:hooks(onPump:{ if pumps==2 {files.remove("/tmp/spz-demo-probe-78"); fp="late"} }, onSleep:{ if sleeps==1 {files.insert("/tmp/spz-demo-ack-78")} }))
 print(r,writes); exit(r && (writes["/tmp/spz-demo-drift-78"] ?? "").contains("current=late") && writes["/tmp/spz-demo-blocked-78"]=="drifted" ? 0:1)
case "no-blocked-marker-without-probe":
 reset(); let r=CaptureAckWait.wait(step:78,deadline:dl,fingerprint:{fp},hooks:hooks(onSleep:{ if sleeps==2 {files.insert("/tmp/spz-demo-ack-78")} }))
 print(r,writes); exit(r && writes.isEmpty ? 0:1)
case "timeout-no-ack":
 reset(); let r=CaptureAckWait.wait(step:78,deadline:dl,fingerprint:{fp},hooks:hooks())
 print(r); exit(!r ? 0:1)
default: exit(2)
}
'''
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);(p/'main.swift').write_text(main);(p/'w.swift').write_text(src)
 subprocess.run([str(swift),'-DSPZ_CI_TESTS',str(p/'main.swift'),str(p/'w.swift'),'-o',str(p/'t')],check=True)
 for sc in ['block-without-probe','probe-pumps-no-drift','probe-drift-recorded-once','probe-removed-returns-to-block','blocked-marker-after-last-check-catches-late-drift','no-blocked-marker-without-probe','timeout-no-ack']:
  r=subprocess.run([str(p/'t'),sc],capture_output=True,text=True)
  assert r.returncode==0,(sc,r.stdout,r.stderr)
  print('PASS',sc,r.stdout.strip().replace('\n',' | '))
