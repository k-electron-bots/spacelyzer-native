#!/bin/bash
# usage: build.sh <out> [sources-dir]   (default sources: Sources/Spacelyzer of this repo)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
export PATH="${SWIFT_BIN:-/tmp/sw/usr/bin}:$PATH"
OUT="$(cd "$(dirname "${1:?out}")" && pwd)/$(basename "$1")"; R="${2:-$REPO/Sources/Spacelyzer}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp -r "$HERE/stubs" "$W/stubs"; mkdir -p "$W/CSpacelyzer"; cp -r "$REPO/Sources/CSpacelyzer/include" "$W/CSpacelyzer/include"
printf 'module CSpacelyzer { header "spacelyzer.h" export * }\n' > "$W/CSpacelyzer/include/module.modulemap"
cp "$HERE"/{shim.swift,check.swift,main.swift,cstub.c} "$W/"
python3 - "$R" "$W" <<'PY'
import sys
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
PY
cd "$W"
for m in UniformTypeIdentifiers AppKit; do swiftc -emit-module -emit-library -module-name $m -I stubs stubs/$m.swift -o stubs/lib$m.so -emit-module-path stubs/$m.swiftmodule; done
clang -c cstub.c -o cstub.o
swiftc -Onone -DSPZ_CI_TESTS -I CSpacelyzer/include -I stubs -L stubs -lAppKit -lUniformTypeIdentifiers -swift-version 5 \
  -Xlinker --unresolved-symbols=ignore-all -Xlinker -rpath -Xlinker "$OUT.lib" \
  AppModel.patched.swift "$R/Engine.swift" "$R/BatchRemoval.swift" "$R/OutlineSelectionSync.swift" "$R/MultiSelectChecks.swift" "$R/CSVExport.swift" \
  verdict.swift check.swift main.swift shim.swift cstub.o -o "$OUT"
mkdir -p "$OUT.lib"; cp stubs/*.so "$OUT.lib/"
