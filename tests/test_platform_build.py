"""Check CI digest handoff and failure propagation without a Docker daemon."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DIGEST = "sha256:" + "a" * 64
FAKE_DOCKER = '''#!/usr/bin/env python3
import json
import os
import sys

print("build progress")
scanner = os.environ.get("SYFT_SCANNER_IMAGE")
if scanner:
    assert "--provenance=mode=max" in sys.argv
    assert "--sbom=generator=" + scanner in sys.argv
else:
    assert not any(arg.startswith("--sbom=") for arg in sys.argv)
if os.environ["SCENARIO"] == "failure":
    sys.exit(42)
metadata = sys.argv[sys.argv.index("--metadata-file") + 1]
digest = os.environ["EXPECTED_DIGEST"] if os.environ["SCENARIO"] == "success" else "bad-digest"
with open(metadata, "w") as target:
    json.dump({"containerimage.digest": digest}, target)
'''


class PlatformBuildTests(unittest.TestCase):
    def run_build(self, scenario, scanner=""):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            docker = directory / "docker"
            docker.write_text(FAKE_DOCKER)
            docker.chmod(0o755)
            metadata = directory / "metadata.json"
            # A failed build must never hand off a digest from an older build.
            metadata.write_text(json.dumps({"containerimage.digest": DIGEST}))
            env = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}",
                       SCENARIO=scenario, EXPECTED_DIGEST=DIGEST,
                       SYFT_SCANNER_IMAGE=scanner)
            return subprocess.run(
                [str(ROOT / "scripts/build-platform.sh"), "linux/arm64", str(metadata),
                 "--output", "type=image,name=test,push-by-digest=true,push=true"],
                env=env, text=True, capture_output=True, timeout=10,
            )

    def test_stdout_contains_only_digest(self):
        result = self.run_build("success", scanner="scanner:test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, DIGEST + "\n")
        self.assertIn("build progress", result.stderr)

    def test_failed_build_does_not_return_stale_digest(self):
        result = self.run_build("failure")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(result.stdout, "")

    def test_invalid_metadata_does_not_return_digest(self):
        result = self.run_build("invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("valid image digest", result.stderr)


if __name__ == "__main__":
    unittest.main()
