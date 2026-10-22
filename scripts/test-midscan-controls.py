from pathlib import Path
import tempfile,shutil,subprocess,os
r=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='midscan-control-') as td:
 w=Path(td)
 for p in ['Cargo.toml','Cargo.lock']:shutil.copy(r/p,w/p)
 shutil.copytree(r/'engine',w/'engine')
 p=w/'engine/tests/ci_scan_gate.rs';original=p.read_text()
 for label,old,new,match in [
 ('no-cancel','spz_scan_cancel(s); spz_ci_scan_gate_release(s);','/* negative: no cancel */ spz_ci_scan_gate_release(s);','midscan cancellation must publish cancelled tree'),
 ('premature-park','let s = f.start(3);','let s = f.start(1);','prior real entry accounting missing')]:
  assert old in original;p.write_text(original.replace(old,new))
  out=subprocess.run(['cargo','test','--locked','--manifest-path',str(w/'Cargo.toml'),'-p','spacelyzer-engine','--features','ci-checks','--test','ci_scan_gate','real_cancel_after_two_completed_directory_enumerations_keeps_prior_entries'],env=dict(os.environ,CARGO_TARGET_DIR=str(w/'target')),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  assert out.returncode==101 and match in out.stdout,(label,out.stdout)
  print('PASS actual Rust negative control',label)
