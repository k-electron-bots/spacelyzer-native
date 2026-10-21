#!/bin/bash
# Proves compare.sh's gate rejects bad outcomes. Uses a fake build.sh whose "binary" prints scripted output, so it needs no Swift toolchain.
# The real checks list still comes from the repo's MultiSelectChecks.swift. Each case states the exact exit code the gate must return.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"; W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir "$W/h"; cp "$HERE/compare.sh" "$W/h/"
cat > "$W/h/build.sh" <<'FB'
#!/bin/bash
case "$2" in */old*) O="$OLD_OUT"; R="$OLD_RC";; *) O="$NEW_OUT"; R="$NEW_RC";; esac
printf '#!/bin/bash\ncat %q\nexit %s\n' "$O" "$R" > "$1"; chmod +x "$1"
FB
chmod +x "$W/h/build.sh"
NAMES=$(grep -o 'Check\.expect("[^"]*"' "$REPO/Sources/Spacelyzer/MultiSelectChecks.swift" | sed 's/Check\.expect("//; s/"$//')
CHK=$(echo "$NAMES" | head -1); N=$(echo "$NAMES" | wc -l)
mk() { # <file> <failing-name-or-none> <drop-last:0|1> <done:0|1>
  : > "$1"; local i=0; while read -r n; do i=$((i+1)); [ "$2" = "$n" ] && echo "FAIL $n detail" >> "$1" || echo "PASS $n" >> "$1"; done <<< "$NAMES"
  [ "$3" = 1 ] && sed -i '$d' "$1"
  if [ "$4" = 1 ]; then echo "DONE passes=$(grep -c '^PASS ' "$1") fails=$(grep -c '^FAIL ' "$1")" >> "$1"; fi; }
mk "$W/allpass" none 0 1; mk "$W/onefail" "$CHK" 0 1; mk "$W/nodone" none 0 0; mk "$W/short" none 1 1; mk "$W/twofail" "$CHK" 0 1; echo "FAIL other-check x" >> "$W/twofail"
sed -i '/^DONE/d' "$W/twofail"; echo "DONE passes=$((N-1)) fails=2" >> "$W/twofail"
: > "$W/crash"; echo "PASS $CHK" > "$W/crash"
BAD=0
t() { # <label> <want-rc> <mode args...> ; env NEW_OUT NEW_RC OLD_OUT OLD_RC preset by caller
  local label="$1" want="$2"; shift 2
  SPZ_REPO="$REPO" bash "$W/h/compare.sh" "$@" >"$W/o" 2>&1; local rc=$?
  if [ "$rc" = "$want" ]; then echo "ok   $label (rc=$rc)"; else echo "BAD  $label want=$want got=$rc"; sed -n 1,3p "$W/o"; BAD=1; fi; }
export NEW_OUT="$W/allpass" NEW_RC=0 OLD_OUT="$W/onefail" OLD_RC=1
t "regress: new all pass, old fails exactly the named check" 0 regress HEAD "$CHK"
OLD_OUT="$W/allpass" OLD_RC=0 t "regress: old also passes (no regression shown)" 1 regress HEAD "$CHK"
OLD_OUT="$W/crash" OLD_RC=139 t "regress: old crashes with signal exit and no DONE" 3 regress HEAD "$CHK"
OLD_OUT="$W/nodone" OLD_RC=1 t "regress: old truncated, no DONE line" 3 regress HEAD "$CHK"
OLD_OUT="$W/short" OLD_RC=1 t "regress: old output missing a declared check" 1 regress HEAD "$CHK"
OLD_OUT="$W/twofail" OLD_RC=1 t "regress: old fails extra unrelated check" 1 regress HEAD "$CHK"
OLD_OUT="$W/onefail" OLD_RC=1 NEW_OUT="$W/onefail" NEW_RC=1 t "regress: new also fails" 1 regress HEAD "$CHK"
OLD_OUT="$W/onefail" OLD_RC=1 NEW_OUT="$W/crash" NEW_RC=139 t "regress: new crashes" 3 regress HEAD "$CHK"
OLD_OUT="$W/onefail" OLD_RC=1 NEW_OUT="$W/short" NEW_RC=0 t "regress: new missing a declared check" 1 regress HEAD "$CHK"
OLD_OUT="$W/onefail" OLD_RC=1 t "regress: check name not declared" 1 regress HEAD no-such-check
NEW_OUT="$W/allpass" NEW_RC=0 t "baseline: all pass" 0 baseline
NEW_OUT="$W/onefail" NEW_RC=1 t "baseline: one failing" 1 baseline
NEW_OUT="$W/crash" NEW_RC=139 t "baseline: crash" 3 baseline
NEW_OUT="$W/nodone" NEW_RC=0 t "baseline: no DONE" 3 baseline
NEW_OUT="$W/short" NEW_RC=0 t "baseline: missing declared check" 1 baseline
[ "$BAD" = 0 ] && echo "SELFTEST ALL OK" || { echo "SELFTEST FAILED"; exit 1; }
