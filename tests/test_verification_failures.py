"""Exercise failure reporting and bounded startup checks without a Docker daemon."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
FAKE_DOCKER = r'''#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["DOCKER_JOURNAL"], "a") as journal:
    journal.write(json.dumps(args) + "\n")
if args[0] == "run":
    if os.environ["SCENARIO"].startswith("run-failure"):
        sys.exit(42)
    print("test-container")
elif args[0] == "inspect" and "-f" in args:
    template = args[args.index("-f") + 1]
    if template == "{{.State.Running}} {{.State.ExitCode}}":
        print("true 0")
    elif ".State.Health.Log" in template:
        print("test health-check diagnostic")
    else:
        print("test container state")
elif args[0] == "logs":
    print("test container logs")
elif args[0] == "rm" and os.environ["SCENARIO"] == "run-failure-cleanup-failure":
    sys.exit(17)
'''


class VerificationFailureTests(unittest.TestCase):
    def run_verifier(self, scenario, cases="contract"):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            docker = directory / "docker"
            docker.write_text(textwrap.dedent(FAKE_DOCKER))
            docker.chmod(0o755)
            journal = directory / "journal"
            env = dict(os.environ)
            env.update(
                PATH=f"{directory}:{env['PATH']}",
                DOCKER_JOURNAL=str(journal), SCENARIO=scenario,
                IMAGE="image-name-must-not-appear-in-error-command",
                TEST_CASES=cases, WAIT_TIMEOUT="1", CURL_TIMEOUT="1",
                TEST_UID="12345", TEST_GID="23456", PREFIX="offline-test",
                TMPDIR=str(directory),
            )
            result = subprocess.run(
                [str(ROOT / "scripts/verify-integration.sh")], env=env,
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
            )
            calls = [json.loads(line) for line in journal.read_text().splitlines()] if journal.exists() else []
            # The verifier must remove its own temporary fixture directory on failure.
            leftovers = [path for path in directory.iterdir() if path.name not in ("docker", "journal")]
            self.assertEqual(leftovers, [])
            return result, calls

    def test_unexpected_docker_failure_reports_diagnostics_before_cleanup(self):
        result, calls = self.run_verifier("run-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("command failed", result.stderr)
        self.assertIn("status 42", result.stderr)
        self.assertIn("test health-check diagnostic", result.stderr)
        self.assertIn("test container logs", result.stderr)
        self.assertNotIn("image-name-must-not-appear-in-error-command", result.stderr)
        commands = [call[0] for call in calls]
        self.assertLess(commands.index("logs"), commands.index("rm"))

    def test_missing_configuration_cannot_hang_forever(self):
        result, calls = self.run_verifier("running")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not reject configuration within 1s", result.stderr)
        self.assertTrue(any(call[0] == "rm" for call in calls))

    def test_cleanup_failure_is_reported_without_hiding_original_failure(self):
        result, _ = self.run_verifier("run-failure-cleanup-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status 42", result.stderr)
        self.assertIn("Cleanup failed", result.stderr)
        self.assertIn("offline-test", result.stderr)

    def test_unknown_case_fails_before_creating_docker_resources(self):
        result, calls = self.run_verifier("running", cases="unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown test case", result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
