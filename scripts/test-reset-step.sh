#!/bin/bash
# Regression cases for the docs-reset step in ci.yml, run under the same shell options as the runner (bash -e {0}) with
# stubbed macOS tools and a throwaway HOME. Linux-safe. Each case states the expected outcome; a wrong outcome exits 1.
set -u
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
python3 - "$WORK/step.sh" <<'PY'
import sys,yaml
d=yaml.safe_load(open('.github/workflows/ci.yml'))
st=[x for x in d['jobs']['macos']['steps'] if x.get('id')=='reset'][0]
open(sys.argv[1],'w').write(st['run'])
PY
mkdir -p "$WORK/bin"
cat > "$WORK/bin/defaults" <<'EOS'
#!/bin/bash
case "$1" in
  read) case "$STUB_DEFAULTS" in absent) echo "Domain $2 does not exist" >&2; exit 1;; present) echo "{ a = 1; }"; exit 0;; broken) echo "cfprefsd unreachable" >&2; exit 1;; esac;;
  delete) [ "$STUB_DEFAULTS" = absent ] && { echo "Domain $2 not found" >&2; exit 1; }; [ "$STUB_DEFAULTS" = present ] && exit 0; exit 1;;
esac
EOS
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/pkill"; printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/killall"
cat > "$WORK/bin/pgrep" <<'EOS'
#!/bin/bash
[ "${STUB_SURVIVOR:-0}" = 1 ] && { echo 123; exit 0; }; exit 1
EOS
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/sleep"
chmod +x "$WORK"/bin/*
fails=0
run() { # name expected(0|1) defaults-state survivor plist-left
  local name="$1" want="$2"; export STUB_DEFAULTS="$3" STUB_SURVIVOR="$4"
  rm -rf "$WORK/home" "$WORK/run"; mkdir -p "$WORK/home/Library/Preferences" "$WORK/run"
  [ "$5" = 1 ] && touch "$WORK/home/Library/Preferences/com.k-electron.spacelyzer-native.plist"
  if [ "$5" = 2 ]; then   # plist present but defaults delete removes nothing: the rm in the step must clear it
    touch "$WORK/home/Library/Preferences/com.k-electron.spacelyzer-native.plist"
  fi
  ( cd "$WORK/run" && HOME="$WORK/home" PATH="$WORK/bin:$PATH" RUNNER_TEMP="$WORK" bash -e "$WORK/step.sh" >"$WORK/out.txt" 2>&1 ); local rc=$?
  local got=$(( rc != 0 ))
  if [ "$got" = "$want" ]; then echo "ok   $name (exit $rc)"; else echo "FAIL $name: wanted failure=$want got exit $rc"; sed 's/^/     /' "$WORK/out.txt" | tail -5; fails=1; fi
}
run "domain absent, no plist, no saved state: passes"        0 absent 0 0
run "plist left by the demo, rm clears it: passes"           0 absent 0 2
run "domain still readable after reset: fails closed"        1 present 0 0
run "defaults read fails for another reason: fails closed"   1 broken 0 0
run "a process survives SIGKILL: fails closed"               1 absent 1 0
if [ -s "$WORK/run/dist/docs-reset-evidence.txt" ]; then echo "evidence file written in last case: yes"; fi
exit $fails
