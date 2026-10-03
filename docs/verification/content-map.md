# Documentation migration map

The former mixed README and rolling roadmap were replaced by purpose-specific material. Git history retains the source versions; there is no old-README document. This map tracks meaningful content, not every repeated sentence.

| Former material | Current home |
|---|---|
| Product overview and capabilities | Root README and visual tour |
| Outline, treemap, Kinds, Largest screenshots and explanation | guide/tour.md |
| First launch, self-signing and Full Disk Access | guide/install.md |
| Allocated bytes, hard links, zero-byte membership, hidden/pending removal guards | guide/space-and-safety.md; verification decisions |
| Rust/Swift ownership, background work, visible-only rows | development/architecture.md |
| Build commands, dependency policy, contributor rules | development/README.md, DEPENDENCIES.md, AGENTS.md |
| Historical scan/filter/layout/publication timings with scope | development/performance.md |
| Epics, stability/memory, removal and future accounting/features | ROADMAP.md |
| Incremental/FSEvents and index/dua-cli evaluations | Existing named evaluation files |
| Failed compilation, captures, minimum-size/menu/focus checks and evidence URLs | verification/checkpoints.md |
| Publication barriers, zero-area semantics, marked-text/external reset, color/contrast and source review decisions | Topic sections in verification/checkpoints.md |
| Current accepted scope, provisional failures and remaining gates | verification/README.md |

Repeated and superseded product promises were not copied into current guides. Historical pending/source-only statements are explicitly historical in the decision/evidence reference.
