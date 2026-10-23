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
cp "$HERE"/{shim.swift,check.swift,removal_selection_probe.swift} "$W/"
python3 - "$W/shim.swift" <<'PY2'
import sys
p=sys.argv[1]; t=open(p).read().split("\n")
i=next(k for k,l in enumerate(t) if "HARNESS STUB: the real one lives" in l)
j=next(k for k in range(i,len(t)) if t[k].rstrip().endswith("} }"))
open(p,"w").write("\n".join(t[:i]+t[j+1:]))
PY2
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
k=v.index('struct ItemDetailsView')
open(w+'/verdict.swift','w').write('import Foundation\nimport CSpacelyzer\n'+v[:k].replace('import SwiftUI','').replace('import CSpacelyzer',''))
a=open(r+'/SpacelyzerApp.swift').read().split('\n')
st=next(k for k,l in enumerate(a) if 'private static func foldersChecks() async {' in l)
en=next(k for k in range(st+1,len(a)) if a[k]=='    }')
bx=next(k for k,l in enumerate(a) if 'private final class Box<T>' in l and k>en)
be=next(k for k in range(bx,len(a)) if a[k].startswith('    }'))
nd=next(l for l in a if 'private static func node(_ t: Tree, _ name: String)' in l)
body='\n'.join(a[st:en+1]); box='\n'.join(a[bx:be+1])
# Slice the existing export checks verbatim, including their real fixture helper.
def method(signature):
    start=next(k for k,l in enumerate(a) if signature in l)
    end=next(k for k in range(start+1,len(a)) if a[k]=='    }')
    return '\n'.join(a[start:end+1])
export_methods='\n'.join(method(sig) for sig in [
    'private static func csvChecks() {',
    'private static func csvExportFlowChecks() async {',
    'private static func fixture(_ tag: String, _ files: [(String, Int)]) -> URL {'])

d=open(r+'/DuplicatesReviewView.swift').read(); i=d.index('enum DuplicateRemoval {'); j=d.index('\n}\n',i)+3
open(w+'/dupremoval.swift','w').write('import Foundation\nimport CSpacelyzer\n'+d[i:j])
def sl(f,key):
    t=open(r+'/'+f).read(); i=t.index(key)
    # include a directly preceding @MainActor line
    pre=t.rfind('\n',0,i-1)+1
    if t[pre:i].strip()=='@MainActor': i=pre
    j=t.index('\n}\n',i)+3
    return t[i:j]
parts=[('TreemapView.swift','final class TreemapPublicationProbe'),('TreemapView.swift','struct TreemapPublicationEvidence'),('DuplicatesReviewView.swift','final class DuplicatesModel'),('SkippedListView.swift','final class SkippedListModel'),('VolumeHeaderView.swift','final class VolumeHeaderModel'),('FullDiskAccessView.swift','enum FullDiskAccessStatus'),('FullDiskAccessView.swift','enum FullDiskAccessProbeOutcome'),('FullDiskAccessView.swift','final class FullDiskAccessModel'),('ExclusionsView.swift','enum ExclusionEditing'),('ExclusionsView.swift','final class ExclusionsModel'),('SpacelyzerApp.swift','final class OpenGate')]
open(w+'/sliced_models.swift','w').write('import Foundation\nimport CSpacelyzer\nimport AppKit\n'+'\n'.join(sl(f,k) for f,k in parts))
open(w+'/folders_exec.swift','w').write('import Foundation\n@MainActor enum FoldersExec {\n'+box+'\n'+nd+'\n'+body+'\n'+export_methods+'\n    static func go() async { await foldersChecks(); csvChecks(); await csvExportFlowChecks() }\n}\n')
PY
cat > "$W/main.swift" <<'M'
import Foundation
@MainActor func go() async {
    await FoldersExec.go(); await MultiSelectChecks.run(); await BatchRemovalChecks.run(); await BatchRemovalExecutionChecks.run(); await BatchUndoChecks.run(); await IdentityGateChecks.run(); await OutlineSelectionSyncChecks.run(); await DuplicatesRemovalChecks.run(); await DuplicatesChecks.run(); await SkippedListChecks.run(); await VolumeChecks.run(); await FullDiskAccessChecks.run(); await ItemReviewChecks.run(); await ExclusionsChecks.run(); await RemovalHistoryChecks.run(); await RemovalSelectionProbe.run()
    print("DONE passes=\(Check.passes) fails=\(Check.fails)")
    exit(Check.fails == 0 ? 0 : 1)
}
await go()
M
cat > "$W/observable_stub.swift" <<'OS'
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<V> { var wrappedValue: V; init(wrappedValue: V) { self.wrappedValue = wrappedValue } }
OS
cd "$W"
for m in UniformTypeIdentifiers AppKit; do swiftc -emit-module -emit-library -module-name $m -I stubs stubs/$m.swift -o stubs/lib$m.so -emit-module-path stubs/$m.swiftmodule; done
swiftc -Onone -DSPZ_CI_TESTS -I CSpacelyzer/include -I stubs -L stubs -lAppKit -lUniformTypeIdentifiers -swift-version 5 \
  -Xlinker --unresolved-symbols=ignore-all -Xlinker -rpath -Xlinker "$OUT.lib" \
  AppModel.patched.swift "$R/Engine.swift" "$R/BatchRemoval.swift" "$R/OutlineSelectionSync.swift" "$R/CSVExport.swift" "$R/MultiSelectChecks.swift" "$R/BatchRemovalChecks.swift" "$R/BatchRemovalExecutionChecks.swift" "$R/BatchUndoChecks.swift" "$R/IdentityGateChecks.swift" "$R/OutlineSelectionSyncChecks.swift" "$R/DuplicatesRemovalChecks.swift" "$R/DuplicatesChecks.swift" "$R/SkippedListChecks.swift" "$R/VolumeChecks.swift" "$R/FullDiskAccessChecks.swift" "$R/ItemReviewChecks.swift" "$R/ExclusionsChecks.swift" "$R/RemovalHistoryChecks.swift" \
  verdict.swift check.swift main.swift shim.swift folders_exec.swift dupremoval.swift sliced_models.swift observable_stub.swift removal_selection_probe.swift -Xlinker "$LIB" -Xlinker -lpthread -Xlinker -ldl -Xlinker -lm -o "$OUT"
mkdir -p "$OUT.lib"; cp stubs/*.so "$OUT.lib/"
