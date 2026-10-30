"""Exercise base/lookup branch drift using disposable repository fixtures."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RenovateAlpineTests(unittest.TestCase):
    def check(self, base="3.24", branch="v3.24", registry=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Dockerfile").write_text(f"FROM docker.io/library/alpine:{base}@sha256:abc\n")
            rules = [{"matchDatasources": ["apk"], "registryUrls": [
                f"https://dl-cdn.alpinelinux.org/alpine?branch={branch}&components=main,community&arch=x86_64"
            ]}] if registry else []
            (root / "renovate.json").write_text(json.dumps({"packageRules": rules}))
            return subprocess.run(
                ["python3", str(ROOT / "scripts/check-renovate-alpine.py"), str(root)],
                text=True, capture_output=True, timeout=10,
            )

    def test_matching_branch(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_patch_base_uses_distribution_branch(self):
        result = self.check(base="3.24.1")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_base_upgrade_requires_registry_upgrade(self):
        result = self.check(base="3.25")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("branch=v3.25", result.stderr)

    def test_registry_upgrade_requires_base_upgrade(self):
        result = self.check(branch="v3.25")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("branch=v3.24", result.stderr)

    def test_registry_is_required(self):
        result = self.check(registry=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing Renovate APK", result.stderr)

    def test_unversioned_base_is_rejected(self):
        result = self.check(base="latest")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("versioned Alpine base", result.stderr)
