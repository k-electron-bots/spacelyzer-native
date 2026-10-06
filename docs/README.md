# Documentation

Spacelyzer has two audiences: people exploring disk space and people building or validating the app. Start with the guide for your task.

## Use the app
- [Install and permissions](guide/install.md)
- [Visual tour](guide/tour.md): earlier authentic CI screenshots, labeled with their checkpoint
- [Branch feature guide](guide/branch-features.md): Folders, CSV export and read-only item review, not UI-verified
- [Space, filters and safe removal](guide/space-and-safety.md)

## Build and understand it
- [Development setup](development/README.md)
- [Architecture](development/architecture.md)
- [Engine CLI reference](development/cli.md)
- [Scoped performance measurements](development/performance.md)
- [Dependency policy](DEPENDENCIES.md)
- [Contributor and safety rules](../AGENTS.md)

## Plan and verify
- [Roadmap](ROADMAP.md): priorities, dependencies and remaining work
- [Verification status](verification/README.md): accepted scope and open gates
- [Checkpoint ledger](verification/checkpoints.md): dated evidence and failed attempts, not current product promises
- [Index-assisted early-results evaluation](EVAL-index-accelerant.md): not implemented
- [Incremental-scan evaluation](EVAL-incremental-scan.md): not implemented

Documentation follows purpose rather than file history. Current behavior belongs in user guides; implementation belongs in development references; measured results and failures belong in verification. A checkpoint changes current status only after its evidence is reviewed.

[Documentation policy by project type](documentation-policy.md) describes the shared approach without requiring an identical tree in every repository.
