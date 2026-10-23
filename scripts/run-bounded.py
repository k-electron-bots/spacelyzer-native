#!/usr/bin/env python3
"""run-bounded.py <seconds> <command...>: run the command, kill it after <seconds>, exit 124 on timeout.
macOS has no timeout(1); every accessibility call in the v1 capture flow goes through this so a blocked app cannot hang a step."""
import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[2:], timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    print("bounded: timed out after %ss: %s" % (sys.argv[1], " ".join(sys.argv[2:4])), file=sys.stderr)
    sys.exit(124)
