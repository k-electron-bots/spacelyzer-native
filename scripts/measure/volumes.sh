#!/bin/bash
# volumes.sh <engine-binary> <outdir> - volume capability probe (measurement-only).
# Verified-capability evidence for non-UTF-8 (EILSEQ) and multi-volume claims:
# create APFS + exFAT DMG volumes, attempt non-UTF-8 name creation on each (errno recorded),
# run engine verify on each mounted volume. No closures asserted beyond recorded errno.
set -u
BIN="$1"; OUT="$2"
mkdir -p "$OUT"
python3 - "$BIN" "$OUT" <<'PY'
import os, subprocess, sys
bin_path, out = sys.argv[1], sys.argv[2]
def probe(mount, label):
    rec = os.path.join(out, f"nonutf8-{label}.txt")
    name = os.path.join(mount, b"spz-nonutf8-\xff\xfe")
    try:
        fd = os.open(name, os.O_CREAT | os.O_WRONLY, 0o644); os.close(fd); os.unlink(name)
        open(rec, "w").write(f"{label}: non-UTF-8 name CREATED (EILSEQ not raised)\n")
    except OSError as e:
        open(rec, "w").write(f"{label}: refused errno={e.errno} ({e.strerror})\n")
for fmt, label, size in [("APFS", "apfs-dmg", "32m"), ("ExFAT", "exfat-dmg", "32m")]:
    dmg = f"/tmp/spz-{label}.dmg"
    subprocess.run(["hdiutil", "create", "-size", size, "-fs", fmt, "-volname", f"spz{label}", dmg, "-ov"], capture_output=True)
    att = subprocess.run(["hdiutil", "attach", dmg, "-nobrowse"], capture_output=True, text=True)
    open(os.path.join(out, f"attach-{label}.log"), "w").write(att.stdout + att.stderr)
    mount = None
    for line in att.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[-1].strip().startswith("/Volumes/"):
            mount = parts[-1].strip()
    if mount:
        try:
            probe(mount, label)
            with open(os.path.join(out, f"verify-{label}.log"), "w") as f:
                subprocess.run([bin_path, "verify", mount], stdout=f, stderr=subprocess.STDOUT)
        finally:
            # detach trap: the volume is always released, even if probe/verify raises
            det = subprocess.run(["hdiutil", "detach", mount, "-force"], capture_output=True, text=True)
            open(os.path.join(out, f"detach-{label}.log"), "w").write(det.stdout + det.stderr)
    else:
        open(os.path.join(out, f"attach-{label}.failed"), "w").write("no mount point parsed")
probe("/", "boot-volume")
PY
