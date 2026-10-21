"""Shell regression tests with stubbed macOS/toolchain commands. No Mac result implied."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / 'scripts/local-mac-check.sh'

class SetupTests(unittest.TestCase):
    def run_setup(self, rustup_rc=0, cargo_rc=0):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder)
            calls = path / 'calls'
            for name, body in {
                'uname': 'echo Darwin',
                'rustup': f'echo rustup >> "$CALLS"; exit {rustup_rc}',
                'cargo': f'echo cargo >> "$CALLS"; exit {cargo_rc}',
            }.items():
                command = path / name
                command.write_text('#!/bin/sh\n' + body + '\n')
                command.chmod(0o700)
            env = dict(os.environ, PATH=str(path) + os.pathsep + os.environ['PATH'], CALLS=str(calls))
            result = subprocess.run(['bash', str(RUNNER), '--setup'], env=env, capture_output=True, text=True)
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_rustup_failure_stops_before_cargo(self):
        result, calls = self.run_setup(rustup_rc=7)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ['rustup'])
        self.assertIn('rustup target add failed', result.stderr)
        self.assertNotIn('setup finished', result.stdout)

    def test_cargo_failure_is_not_success(self):
        result, calls = self.run_setup(cargo_rc=9)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ['rustup', 'cargo'])
        self.assertIn('cargo fetch failed', result.stderr)
        self.assertNotIn('setup finished', result.stdout)

    def test_success_requires_both_commands(self):
        result, calls = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['rustup', 'cargo'])
        self.assertIn('setup finished', result.stdout)

if __name__ == '__main__':
    unittest.main()
