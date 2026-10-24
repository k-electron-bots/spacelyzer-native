#!/bin/bash
# The original parent20s cap remains; Python stage budget19s leaves final flush.
set -e
exec python3 scripts/capture-stages.py wide "${1:?helper}" "${2:?pid}" "${3:?out}" "${4:?bound}"
