#!/bin/bash
# Dump external symbols (defined AND undefined) of an archive/object/binary with LLVM's nm, one
# output file per architecture slice, fail closed. Usage: dump-symbols.sh FILE OUTDIR
#   SPZ_EXPECT_ARCHS  space-separated Mach-O arch names to require (default "arm64 x86_64" on
#                     Darwin, none elsewhere: then FILE is dumped as a single thin file).
#   SPZ_LLVM_NM       explicit llvm-nm path. If set it is the ONLY candidate (no install fallback).
# Otherwise llvm-nm comes from the rustup `llvm-tools` component of the active toolchain; if it is
# missing, `rustup component add llvm-tools` is attempted and a failure is a hard failure.
# Apple's own `nm` is deliberately NOT used (it exited non-zero on the universal archive in Mac
# run 39832527366 with its stderr hidden; cause unproven).
# Output: OUTDIR/<arch>.txt (or OUTDIR/thin.txt); each must be non-empty; llvm-nm stderr is kept in
# OUTDIR/<arch>.err and its first lines are printed on failure. Exit 1 on any problem.
set -euo pipefail
file="${1:?file}"; out="${2:?outdir}"
[ -f "$file" ] && [ -r "$file" ] && [ -s "$file" ] || { echo "dump-symbols: missing, unreadable or empty: $file" >&2; exit 1; }
find_nm() {
  if [ -n "${SPZ_LLVM_NM:-}" ]; then [ -x "$SPZ_LLVM_NM" ] && echo "$SPZ_LLVM_NM" && return 0; return 1; fi
  local sysroot host cand
  sysroot=$(rustc --print sysroot 2>/dev/null) && host=$(rustc -vV 2>/dev/null | sed -n 's/^host: //p') || return 1
  cand="$sysroot/lib/rustlib/$host/bin/llvm-nm"
  [ -x "$cand" ] && { echo "$cand"; return 0; }
  rustup component add llvm-tools >&2 || return 1
  [ -x "$cand" ] && { echo "$cand"; return 0; }
  return 1
}
NM=$(find_nm) || { echo "dump-symbols: llvm-nm unavailable (rustup component llvm-tools could not be found or installed); cannot inspect symbols: $file" >&2; exit 1; }
archs="${SPZ_EXPECT_ARCHS-}"
if [ -z "${SPZ_EXPECT_ARCHS+x}" ] && [ "$(uname)" = Darwin ]; then archs="arm64 x86_64"; fi
mkdir -p "$out"
# Optional diagnostics: SPZ_DIAG_DIR gets a copy of every dump (and .err) even when this script fails. Best effort only.
if [ -n "${SPZ_DIAG_DIR:-}" ]; then
  trap 'dd="$SPZ_DIAG_DIR/symbols/$(basename "$file")-$$"; mkdir -p "$dd" 2>/dev/null && cp "$out"/* "$dd"/ 2>/dev/null || true' EXIT
fi
dump() { # label, extra args...
  local label="$1"; shift
  if ! "$NM" -g "$@" "$file" > "$out/$label.txt" 2> "$out/$label.err"; then
    echo "dump-symbols: llvm-nm failed for slice '$label' of $file; stderr (first 10 lines):" >&2; head -10 "$out/$label.err" >&2 || true; exit 1
  fi
  [ -s "$out/$label.txt" ] || { echo "dump-symbols: llvm-nm produced no symbols for slice '$label' of $file" >&2; exit 1; }
}
if [ -n "$archs" ]; then for a in $archs; do dump "$a" --arch="$a"; done; else dump thin; fi
