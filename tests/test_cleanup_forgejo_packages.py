"""Offline safety checks for registry retention; no Docker or credentials needed."""

import copy
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.parse


SPEC = importlib.util.spec_from_file_location(
    "retention", Path(__file__).resolve().parents[1] / "scripts/cleanup-forgejo-packages.py"
)
retention = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(retention)


def package(number, **overrides):
    entry = {
        "type": "container",
        "name": "nginx",
        "version": f"sha-{number:012x}",
        "id": number,
        "created_at": f"2026-01-01T00:00:{number:02d}Z",
    }
    entry.update(overrides)
    return entry


def inventory(count=12):
    return [package(0, version="latest")] + [package(i) for i in range(1, count + 1)]


class Response(io.BytesIO):
    def __init__(self, payload=None, status=200):
        super().__init__(json.dumps(payload).encode())
        self.status = status


class SelectionTests(unittest.TestCase):
    def test_keeps_newest_ten_regardless_of_api_order(self):
        entries = inventory()
        entries.reverse()
        self.assertEqual(
            [entry["version"] for entry in retention.select_deletions(entries, "nginx")],
            [package(2)["version"], package(1)["version"]],
        )

    def test_small_inventory_deletes_nothing(self):
        for count in (0, 1, 10):
            with self.subTest(count=count):
                self.assertEqual(retention.select_deletions(inventory(count), "nginx"), [])

    def test_preserves_latest_unrelated_tags_digests_and_packages(self):
        entries = inventory() + [
            package(20, version="stable"),
            package(21, version="sha-abcdef"),
            package(22, version="sha-ABCDEF123456"),
            package(23, version="sha-abcdef123456-extra"),
            package(24, version="sha256:" + "a" * 64),
            package(25, name="other"),
            package(26, type="generic"),
        ]
        self.assertEqual(retention.select_deletions(entries, "nginx"), [package(2), package(1)])

    def test_orders_by_actual_time_and_breaks_ties_by_id(self):
        entries = inventory(11)
        for entry in entries[1:]:
            entry["created_at"] = "2026-01-01T00:00:00Z"
        # Same instant, expressed in another timezone.
        entries[1]["created_at"] = "2025-12-31T19:00:00-05:00"
        self.assertEqual(retention.select_deletions(entries, "nginx"), [entries[1]])

    def test_requires_exactly_one_latest(self):
        for entries in (inventory()[1:], inventory() + [package(30, version="latest")]):
            with self.subTest(entries=entries):
                with self.assertRaises(ValueError):
                    retention.select_deletions(entries, "nginx")

    def test_rejects_malformed_inventory(self):
        for entry in (None, [], {}, package(1, type=None), package(1, version=123)):
            with self.subTest(entry=entry):
                with self.assertRaises(ValueError):
                    retention.select_deletions(inventory() + [entry], "nginx")

    def test_rejects_malformed_candidate_metadata(self):
        for overrides in (
            {"id": True}, {"id": "1"}, {"created_at": None},
            {"created_at": "invalid"}, {"created_at": "2026-01-01T00:00:00"},
        ):
            with self.subTest(overrides=overrides):
                entries = inventory()
                entries[1].update(overrides)
                with self.assertRaises(ValueError):
                    retention.select_deletions(entries, "nginx")

    def test_rejects_duplicate_sha_tags_and_ids(self):
        for duplicate in (package(1, id=30), package(30, id=1)):
            with self.subTest(duplicate=duplicate):
                with self.assertRaises(ValueError):
                    retention.select_deletions(inventory() + [duplicate], "nginx")

    def test_does_not_mutate_inventory(self):
        entries = inventory()
        before = copy.deepcopy(entries)
        retention.select_deletions(entries, "nginx")
        self.assertEqual(entries, before)


class ApiTests(unittest.TestCase):
    @patch.object(retention.urllib.request, "urlopen")
    def test_pagination_continues_until_empty_even_with_short_pages(self, urlopen):
        urlopen.side_effect = [Response([package(1)]), Response([package(2)]), Response([])]
        result = retention.fetch_packages("https://registry.invalid/api/v1", "owner space", "nginx", "test")
        self.assertEqual(result, [package(1), package(2)])
        pages = []
        for call in urlopen.call_args_list:
            request = call.args[0]
            parsed = urllib.parse.urlsplit(request.full_url)
            self.assertIn("/owner%20space", parsed.path)
            query = urllib.parse.parse_qs(parsed.query)
            self.assertEqual(query["q"], ["nginx"])
            pages.append(query["page"][0])
            self.assertEqual(request.get_header("Authorization"), "token test")
            self.assertGreater(call.kwargs["timeout"], 0)
        self.assertEqual(pages, ["1", "2", "3"])

    @patch.object(retention.urllib.request, "urlopen")
    def test_listing_rejects_non_array_or_unexpected_status(self, urlopen):
        for payload, status in (({}, 200), ([], 201)):
            with self.subTest(payload=payload, status=status):
                urlopen.return_value = Response(payload, status)
                with self.assertRaises(ValueError):
                    retention.fetch_packages("https://registry.invalid", "owner", "nginx", "test")

    @patch.object(retention.urllib.request, "urlopen")
    def test_cleanup_deletes_only_selected_tags(self, urlopen):
        urlopen.side_effect = [Response(inventory()), Response([]), Response(status=204), Response(status=204)]
        with patch("sys.stdout", new_callable=io.StringIO):
            retention.cleanup("https://registry.invalid/api/v1", "OWNER/NGINX", "test")
        deletions = [call.args[0] for call in urlopen.call_args_list if call.args[0].get_method() == "DELETE"]
        self.assertEqual(
            [request.full_url for request in deletions],
            [f"https://registry.invalid/api/v1/packages/owner/container/nginx/{package(i)['version']}" for i in (2, 1)],
        )

    @patch.object(retention.urllib.request, "urlopen")
    def test_invalid_inventory_causes_no_deletions(self, urlopen):
        urlopen.side_effect = [Response(inventory()[1:]), Response([])]
        with self.assertRaises(ValueError):
            retention.cleanup("https://registry.invalid", "owner/nginx", "test")
        self.assertTrue(all(call.args[0].get_method() == "GET" for call in urlopen.call_args_list))

    @patch.object(retention.urllib.request, "urlopen")
    def test_deletion_failure_stops_further_deletions(self, urlopen):
        urlopen.side_effect = [Response(inventory()), Response([]), Response(status=200)]
        with patch("sys.stdout", new_callable=io.StringIO):
            with self.assertRaises(ValueError):
                retention.cleanup("https://registry.invalid", "owner/nginx", "test")
        self.assertEqual(urlopen.call_count, 3)


if __name__ == "__main__":
    unittest.main()
