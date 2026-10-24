# October 23: compact history demonstrated, full capture gate still failed

[Run 40050466225](https://github.com/k-electron-bots/spacelyzer-native/actions/runs/40050466225)
tested source `9db328b54ac198ffbe49f66038e48fe9ae6cf0d6`, tree
`42be79377fc3ab5f6e69ddf8433491b860f29f31`. The whole run **failed**. No retry,
release, DMG, scale or soak follows automatically.

## Native execution and inspected images

- Universal engine, shipping Swift, helper typecheck/build and CI-only app built.
- Ordering: `PASS 166 required checks, each exactly once`; no FAIL.
- UI assertions: 178 PASS, no FAIL. Those are separate from capture fidelity.
- All 81 demo screenshots and both artifact sets uploaded.
- The six original v1 window-only images were directly inspected: exclusions,
  duplicates, exact-file Trash confirmation, clean dismissed-result done state,
  compact Removal History and FDA banner. Intended content is visible.
- Compact history now opens through the native toolbar overflow. The live
  snapshot and pixels show `Removed this session`, `Backup 2025.zip`, its sample
  Archives path, 188.7 MB and Put Back. This is actual visible content, not a
  background list or model-state substitute. The capture does not exercise
  Put Back. Wider presentation is not established.

The README, visual tour and safety guide use five unmodified window-only images
from this artifact. [Exact files and hashes](screenshots-40050466225.json).
Older overview, Kinds, on-disk review and installer images remain named earlier
captures; this is not a wholly new screenshot set. No full-screen demo image is
published as a window-only documentation image.

## Failed acceptance and precise limits

The named observed-sheet-v1 gate failed. Native step78 remained
`sheet=true keyIsSheet=true alertModel=false sheetId=unknown sheetRows=1`.
The normal screenshot visibly shows Not scanned, the explanatory qualifier and
one locked row, but the external observer returned:

```
complete=false identity=unknown rows=0 scopeCount=0 texts=[]
reason="attribute AXWindows error -25204"
```

The launched PID, executable, source and native `ps` start pin succeeded. Probe
refusal and partial files were retained. No bound image/manifest was produced;
the install-image and actual observed gate correctly refused it. A correct
looking normal screenshot does not manufacture a bound external observation or
turn the native accessor green. Why AXWindows failed remains unresolved.

The added same-session wide-history stage failed after successful no-panel
observation. Its retained `history-wide-resize.txt` says exactly:

```
resize dimensions not observed
```

No wide image exists. The helper did not log requested versus actual dimensions,
so the cause is unknown. Display constraints/clamping or settling are hypotheses,
not findings. The normal demo image is 1024x768; that alone does not prove which
resize check failed. All six original shots passed the script, but wide evidence
is additionally required, so v1 capture stayed incomplete.

Final gate: `asserts=failure v1cap=failure`. Continue-on-error conclusions do not
replace these outcomes. Full app compilation and compact history opening are
now native evidence for this source; external identity export, wide history
position/content and complete capture acceptance remain open.

## Documentation closeout scope

The new cleanup pictures and user-facing descriptions are refreshed from valid
evidence. Product readiness is not closed. Actual IME input and real CSV save
panel/file/import behavior remain unverified; CSV seam checks are not a real
save-panel result. The older Linux 4 KB ancestor anomaly remains unexplained,
and hard-link attribution decisions retain their own scope. No performance,
release or complete-documentation claim follows from these screenshots.
