# Observed-sheet-v1 acceptance rule

Landed in b412b3fe after independent engineering review. This implements the
explicit new observed-sheet-v1 rule. The standalone
native check still fails raw `sheetId=unknown`. Workflow assertions now invoke
the named observed gate, not silent error suppression. This is not a claim
that the existing native accessor passed.

## Exact proposed distinction

Report two separate results:

- Native accessor: the raw value, including `unknown`, never rewritten.
- Observed sheet identity: native observed identity corroborated by a separately bound, complete external AX observation
  satisfying the intended-sheet criterion. Both native agreement and unknown
  require the witness under the candidate rule.

An unknown native accessor is not contrary identity evidence. A positive native
identity other than Not scanned is contrary evidence and must refuse. The new
route could establish observed Not scanned identity while explicitly leaving
the native accessor unverified. This is an acceptance rule change and requires
review of any further criterion change. Actual gate tests are implemented below.

## Proposed required external evidence

All existing step78 window, attached-sheet/key-sheet, no-alert, dimension and
loaded-content requirements remain. Additionally require:

1. A complete external result from the exact launched executable/PID/process
   start and checkout SHA. Actual PID on every visited node, one independent
   AXSheet related to the focused window, no truncation, cycle, bad type or AX
   read error. Shared DAG nodes do not create independent sheets.
2. Exact observed Not scanned headline and exact explanatory qualifier, actual
   loaded AXRow nodes within that sheet, and no contradictory removal result.
   Model intent, known fixture text or a background row is never content proof.
3. Exact step78 producer UUID/raw PID/source/step; unchanged producer ready/raw,
   process identity and source before and after probe and image capture, with
   no ack present. Fresh output per token, no replay. Probe8s/image4s/outer18s
   within existing30s ack wait. Incomplete/timeout records cannot pass.
4. Uploaded original raw bytes, external JSON, capture image and complete binding
   manifest. Recompute raw/image hashes; verify external JSON identity and all
   bound identifiers rather than trusting a summary flag in binding.json.
   The published manifest hashes raw/image, not external JSON: the
   implemented gate would also need to hash/bind the external bytes and source
   provenance consistently. This is a new required implementation detail.
5. Gate consumes the exact externally captured image, not an unrelated normal
   screenshot. Human pixel review still required before claiming v1 capture
   readiness. Gate output must name `external-AXUIElement` explicitly, retain
   `nativeAccessorPassed=false` for unknown and never describe unknown as a
   native accessor pass.

## Required implementation controls, before any gate change

Execute the actual proposed gate, not only mocked observer scenarios. Positive:
complete correctly bound external unknown/native route, and native Not scanned
agreement. Negative: missing raw/ready/image/manifest/external record; stale PID,
start, executable, SHA, step, token, replay; acknowledged capture; pre/post state
turnover; file tampering; mismatched hashes; forged summary booleans; external
positive missing exact text/qualifier/row/scope/focus/PID; native positive conflict;
ambiguous scopes; AX read/type errors; traversal cap/cycle; timeout/incomplete.
Mutation neutralizing each load-bearing check must make a negative case fail.

Do not bypass the legacy gate by simply suppressing its error string. Either
refactor shared validation into explicit native/observed criteria or introduce
an explicitly named observed gate with a reviewed call site; preserve all other
step/alert/history checks unchanged. Raw native failure remains separately
visible. Both workflow copies must consume the same exact image/manifest route.

## Native unknowns and payoff

Offline controls can prove production gate logic rejects hostile evidence and
that the helper reads specified declared AX graphs. They cannot prove macOS ps
formatting or real Not scanned text/row export. A later native attempt needs the
actual export, matching process/source/token/image records and pixel review.
History must independently open the existing visible history popover with the
just-removed entry. None of this establishes it by intent or model state.


## Local implementation and executed evidence

The actual `check-observed-demo-state.py` gate invokes shared legacy window,
size, sheet, alert and row checks, with an explicit identity callback. It does
not filter native error strings. `verify_observed_evidence` recomputes raw,
external JSON and image hashes, validates all caller pins/copies/anchor fields,
three pre/post observations, and a unique complete supervisor. Both workflow
copies install the exact bound image before ack, then run the observed gate
with checkout SHA and launched executable as caller pins. They retain the
standalone native failure report separately. No history criterion changes.

Executed synthetic artifact tests run the real binding and actual gate against
hostile bytes, including validly rehashed bad observed content. Sixteen targeted
production-check removal mutations are caught by the real hostile suite. These
are executable logic controls, not native AX export proof or an authenticity
signature: a fully compromised producer able to forge all files is out of scope.
Pre/post observations are captured by the trusted runner while unacknowledged;
the later artifact gate validates their consistency, not current process life
after the demo has ended.

The history repair candidate is landed with user approval of the anchor change,
but is still visually unverified. Its
root-bound popover could change position at narrow AND wide widths; presentation
UX and pixels need review before any landing/readiness decision.
