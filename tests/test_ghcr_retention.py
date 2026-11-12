import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("retention", Path(__file__).resolve().parents[1] / "scripts/expired-ghcr-versions.py")
retention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retention)


class RetentionTests(unittest.TestCase):
    def version(self, identifier, tags):
        return {"id": identifier, "created_at": f"2026-01-{identifier:02d}", "metadata": {"container": {"tags": tags}}}

    def test_preserves_other_tags_and_untagged_versions(self):
        pages = [[self.version(1, ["sha-aaaaaaaaaaaa"]), self.version(2, ["sha-bbbbbbbbbbbb"])],
                 [self.version(3, ["sha-cccccccccccc", "latest"]), self.version(4, []),
                  self.version(5, ["sha-dddddddddddd", "v1"])]]
        self.assertEqual(retention.expired_versions(pages, keep=1), [1])

    def test_rejects_invalid_ids(self):
        with self.assertRaises(ValueError):
            retention.expired_versions([[self.version(True, ["sha-aaaaaaaaaaaa"])]])
