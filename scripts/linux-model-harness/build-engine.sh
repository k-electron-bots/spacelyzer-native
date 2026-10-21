#!/bin/bash
# usage: build-engine.sh <out> [sources-dir]
# Like build.sh, but links the REAL Rust engine (cargo staticlib built from engine/) instead of cstub.c, and compiles the real
# foldersChecks() function sliced verbatim out of SpacelyzerApp.swift (everything from "private static func foldersChecks" to its closing brace,
# plus the Box helper and node()). SpacelyzerApp.swift itself (AppKit UI) is NOT compiled.
# What is real: Engine.swift, the Rust engine (Linux scan path), AppModel (trashItem default closure replaced, HARNESS-ONLY), the check bodies.
# What is stubbed: AppKit and UniformTypeIdentifiers (empty-ish stubs), QuickLook, DuplicateRemoval. Rust scan code for macOS (scan_macos.rs) is not exercised.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export PATH="${SWIFT_BIN:-/tmp/sw/usr/bin}:$HOME/.cargo/bin:$PATH"
OUT="$(cd "$(dirname "${1:?out}")" && pwd)/$(basename "$1")"; R="${2:-$REPO/Sources/Spacelyzer}"
LIB="${SPZ_ENGINE_LIB:-$REPO/target/release/libspacelyzer_engine.a}"
[ -f "$LIB" ] || (cd "$REPO" && cargo build --release -p spacelyzer-engine >/dev/null 2>&1) || true
[ -f "$LIB" ] || { echo "engine staticlib missing: $LIB"; exit 4; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp -r "$HERE/stubs" "$W/stubs"; mkdir -p "$W/CSpacelyzer"; cp -r "$REPO/Sources/CSpacelyzer/include" "$W/CSpacelyzer/include"
printf 'module CSpacelyzer { header "spacelyzer.h" export * }\n' > "$W/CSpacelyzer/include/module.modulemap"
cp "$HERE"/{shim.swift,check.swift} "$W/"
python3 - "$R" "$W" <<'PY'
import sys,re
r,w=sys.argv[1:3]
s=open(r+'/AppModel.swift').read()
o='''    var trashItem: (URL) throws -> URL = { url in
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out! as URL
    }'''
assert o in s, 'trashItem closure changed; update the harness replacement'
open(w+'/AppModel.patched.swift','w').write(s.replace(o,'    var trashItem: (URL) throws -> URL = { url in url }   // HARNESS-ONLY'))
v=open(r+'/ItemReview.swift').read(); i=v.index('enum IdentityVerdict'); j=v.index('\n}\n',i)+3
open(w+'/verdict.swift','w').write('import Foundation\n'+v[i:j])
a=open(r+'/SpacelyzerApp.swift').read().split('\n')
st=next(k for k,l in enumerate(a) if 'private static func foldersChecks() async {' in l)
en=next(k for k in range(st+1,len(a)) if a[k]=='    }')
bx=next(k for k,l in enumerate(a) if 'private final class Box<T>' in l and k>en)
be=next(k for k in range(bx,len(a)) if a[k].startswith('    }'))
nd=next(l for l in a if 'private static func node(_ t: Tree, _ name: String)' in l)
body='\n'.join(a[st:en+1]); box='\n'.join(a[bx:be+1])
open(w+'/folders_exec.swift','w').write('import Foundation\n@MainActor enum FoldersExec {\n'+box+'\n'+nd+'\n'+body+'\n    static func go() async { await foldersChecks() }\n}\n')
PY
cat > "$W/main.swift" <<'M'
import Foundation
@MainActor func go() async {
    await FoldersExec.go()
    print("DONE passes=\(Check.passes) fails=\(Check.fails)")
    exit(Check.fails == 0 ? 0 : 1)
}
await go()
M
cd "$W"
for m in UniformTypeIdentifiers AppKit; do swiftc -emit-module -emit-library -module-name $m -I stubs stubs/$m.swift -o stubs/lib$m.so -emit-module-path stubs/$m.swiftmodule; done
swiftc -Onone -DSPZ_CI_TESTS -I CSpacelyzer/include -I stubs -L stubs -lAppKit -lUniformTypeIdentifiers -swift-version 5 \
  -Xlinker --unresolved-symbols=ignore-all -Xlinker -rpath -Xlinker "$OUT.lib" \
  AppModel.patched.swift "$R/Engine.swift" "$R/BatchRemoval.swift" "$R/OutlineSelectionSync.swift" "$R/CSVExport.swift" \
  verdict.swift check.swift main.swift shim.swift folders_exec.swift -Xlinker "$LIB" -Xlinker -lpthread -Xlinker -ldl -Xlinker -lm -o "$OUT"
mkdir -p "$OUT.lib"; cp stubs/*.so "$OUT.lib/"
