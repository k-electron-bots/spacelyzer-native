#!/bin/bash
# Dependency-aware v1 capture: independent fixture phases continue on failure.
# Same original165s budget, safe dependent cleanup checks remain in phase script.
exec python3 scripts/run-v1-capture.py "${1:?app}" "${2:?out}"
