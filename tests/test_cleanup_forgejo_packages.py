"""Offline contract tests for the Forgejo package cleanup helper."""

import importlib.util
import io
import json
import os
from contextlib import redirect_stdout
from pathlib import Path
import unittest
from unittest import mock
import urllib.error
import urllib.parse
import urllib.request


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "cleanup-forgejo-packages.py"
API_URL = "https://forgejo.example.invalid/api/v1"
TOKEN = "unit-test-placeholder"
NAME = "docker-nginx"


def package(version, **fields):
    return {"type": "container", "name": NAME, "version": version, **fields}


def sha_packages(count, **fields):
    return [
        package(
            f"sha-{number:012x}",
            id=number,
            created_at=f"2026-01-01T00:00:{number % 60:02d}Z",
            **fields,
        )
        for number in range(1, count + 1)
    ]


class Response(io.BytesIO):
    def __init__(self, payload=None, status=200, raw=None):
        super().__init__(json.dumps(payload).encode() if raw is None else raw)
        self.status = status

    def getcode(self):
        return self.status


class CleanupTests(unittest.TestCase):
    def setUp(self):
        # Patch before loading the script so even accidental import-time I/O is blocked.
        self.urlopen = self.enterContext(
            mock.patch(
                "urllib.request.urlopen",
                side_effect=AssertionError("Unexpected network request"),
            )
        )
        spec = importlib.util.spec_from_file_location("cleanup_forgejo_packages", SCRIPT)
        self.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.helper)
        self.urlopen.assert_not_called()
        self.requests = []

    def serve(self, pages, *, delete_status=204, delete_error=None):
        pending = iter(pages)
        self.requests = []

        def urlopen(request, *, timeout):
            self.assertIsInstance(request, urllib.request.Request)
            self.assertEqual(timeout, 30)
            self.assertEqual(request.get_header("Authorization"), f"token {TOKEN}")
            self.requests.append(request)
            method = request.get_method()
            if method == "GET":
                try:
                    page = next(pending)
                except StopIteration:
                    self.fail("Unexpected GET beyond the configured empty terminal page")
                if isinstance(page, Exception):
                    raise page
                return page if isinstance(page, Response) else Response(page)
            self.assertEqual(method, "DELETE")
            sentinel = object()
            self.assertIs(
                next(pending, sentinel),
                sentinel,
                "Deletion started before all inventory pages were fetched",
            )
            if delete_error is not None:
                raise delete_error
            return Response(status=delete_status)

        self.urlopen.side_effect = urlopen

    def cleanup(self, repository="Owner/docker-nginx"):
        output = io.StringIO()
        with redirect_stdout(output):
            self.helper.cleanup(API_URL, repository, TOKEN)
        self.assertNotIn(TOKEN, output.getvalue())
        return output.getvalue()

    def deletions(self):
        return [request for request in self.requests if request.get_method() == "DELETE"]

    def assert_invalid_inventory(self, inventory):
        self.serve([inventory, []])
        with self.assertRaises(ValueError):
            self.cleanup()
        self.assertEqual(self.deletions(), [])

    def test_retention_boundaries(self):
        for count in (0, 1, 9, 10, 11, 14):
            with self.subTest(count=count):
                candidates = sha_packages(count)
                inventory = [package("latest"), *reversed(candidates)]
                expected = list(reversed(candidates))[10:]
                selected = self.helper.select_deletions(inventory, NAME)
                self.assertEqual(selected, expected)
                for actual, original in zip(selected, expected):
                    self.assertIs(actual, original)
                self.serve([inventory, []])
                output = self.cleanup()
                self.assertEqual(
                    [request.full_url.rsplit("/", 1)[1] for request in self.deletions()],
                    [item["version"] for item in expected],
                )
                for item in expected:
                    self.assertIn(item["version"], output)
                self.assertRegex(output, rf"\b{len(expected)}\b")

    def test_latest_must_exist_exactly_once(self):
        candidates = sha_packages(12)
        for latest_entries in (
            [],
            [package("latest"), package("latest")],
            [package("latest", name=NAME + "-other")],
            [package("latest", type="generic")],
            [package("LATEST")],
        ):
            with self.subTest(latest_entries=latest_entries):
                inventory = [*candidates, *latest_entries]
                with self.assertRaises(ValueError):
                    self.helper.select_deletions(inventory, NAME)
                self.assert_invalid_inventory(inventory)

    def test_unrelated_packages_and_non_sha_versions_are_preserved(self):
        candidates = sha_packages(12)
        ignored = [
            package("latest", name=NAME + "-extra"),
            package("latest", name="prefix-" + NAME),
            package("latest", name=NAME.upper()),
            package("latest", type="generic"),
            package("sha-000000000001", name=NAME + "-extra"),
            package("sha-000000000001", type="generic"),
            package("sha256:" + "a" * 64),
            package(""),
            package("v1.2.3"),
            package("stable", id=False, created_at="not-a-timestamp"),
            package("sha-0123456789AB"),
            package("sha-0123456789a"),
            package("sha-0123456789abc"),
            package("sha-0123456789ab-1"),
            package("prefix-sha-0123456789ab"),
            package("sha-0123456789ab\n"),
        ]
        inventory = [*ignored, package("latest"), *candidates]
        self.assertEqual(
            self.helper.select_deletions(inventory, NAME),
            [candidates[1], candidates[0]],
        )
        self.serve([inventory, []])
        self.cleanup()
        self.assertEqual(len(self.deletions()), 2)

    def test_timestamp_ties_use_numeric_id_descending(self):
        candidates = sha_packages(14)
        for item in candidates:
            item["created_at"] = "2026-01-01T00:00:00Z"
        inventory = [package("latest"), *candidates[::2], *candidates[1::2]]
        self.assertEqual(
            [item["id"] for item in self.helper.select_deletions(inventory, NAME)],
            [4, 3, 2, 1],
        )

    def test_timestamps_order_by_instant_not_string_or_id(self):
        newer = sha_packages(10)
        for item in newer:
            item["created_at"] = "2026-02-01T00:00:00Z"
        older = [
            package("sha-aaaaaaaaaaaa", id=100, created_at="2026-01-01T01:00:00+02:00"),
            package("sha-bbbbbbbbbbbb", id=200, created_at="2025-12-31T23:30:00Z"),
            package("sha-cccccccccccc", id=300, created_at="2025-12-31T18:00:00-05:00"),
            package("sha-dddddddddddd", id=400, created_at="2025-12-31T23:00:00.5+00:00"),
        ]
        self.assertEqual(
            self.helper.select_deletions([package("latest"), *older, *newer], NAME),
            [older[1], older[3], older[2], older[0]],
        )

    def test_fetch_returns_all_objects_without_filtering(self):
        entries = [package("latest"), package("v1", name="other", type="generic")]
        self.serve([[entries[0]], [entries[1]], []])
        self.assertEqual(self.helper.fetch_packages(API_URL, "owner", NAME, TOKEN), entries)
        self.assertEqual(len(self.requests), 3)

    def test_full_and_server_capped_pages_are_exhausted_before_deletion(self):
        for page_size in (50, 7, 1):
            with self.subTest(page_size=page_size):
                candidates = sha_packages(63)
                inventory = [*candidates, package("latest")]
                pages = [
                    inventory[start : start + page_size]
                    for start in range(0, len(inventory), page_size)
                ]
                self.serve([*pages, []])
                self.cleanup()
                gets = [request for request in self.requests if request.get_method() == "GET"]
                self.assertEqual(len(gets), len(pages) + 1)
                for number, request in enumerate(gets, 1):
                    self.assertEqual(
                        urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query),
                        {"type": ["container"], "q": [NAME], "page": [str(number)], "limit": ["50"]},
                    )
                self.assertEqual(len(self.deletions()), 53)
                self.assertEqual(
                    [request.get_method() for request in self.requests],
                    ["GET"] * (len(pages) + 1) + ["DELETE"] * 53,
                )

    def test_duplicate_latest_on_later_page_prevents_all_deletions(self):
        self.serve([[package("latest"), *sha_packages(12)], [package("latest")], []])
        with self.assertRaises(ValueError):
            self.cleanup()
        self.assertEqual(self.deletions(), [])

    def test_owner_is_encoded_as_one_path_component(self):
        owner = "Ow/ner ?#%+é"
        name = "image/name ?#%+é"
        self.serve([[]])
        self.helper.fetch_packages(API_URL, owner, name, TOKEN)
        parsed = urllib.parse.urlsplit(self.requests[0].full_url)
        self.assertEqual(parsed.path, "/api/v1/packages/" + urllib.parse.quote(owner, safe=""))
        self.assertEqual(parsed.fragment, "")
        self.assertEqual(
            urllib.parse.parse_qs(parsed.query),
            {"type": ["container"], "q": [name], "page": ["1"], "limit": ["50"]},
        )

    def test_cleanup_lowercases_repository_and_encodes_delete_path(self):
        repository = "Ow Ner+%é/ImAge/Sub ?#%+É"
        owner, name = repository.lower().split("/", 1)
        inventory = [package("latest", name=name), *sha_packages(11, name=name)]
        self.serve([inventory, []])
        self.cleanup(repository)
        get_url = urllib.parse.urlsplit(self.requests[0].full_url)
        self.assertEqual(get_url.path, "/api/v1/packages/" + urllib.parse.quote(owner, safe=""))
        self.assertEqual(urllib.parse.parse_qs(get_url.query)["q"], [name])
        self.assertEqual(
            [request.full_url for request in self.deletions()],
            [
                f"{API_URL}/packages/{urllib.parse.quote(owner, safe='')}"
                f"/container/{urllib.parse.quote(name, safe='')}/sha-000000000001"
            ],
        )

    def test_non_array_pages_fail_without_deletion(self):
        for payload in ({}, {"packages": []}, None, "not an array", 1, True):
            with self.subTest(payload=payload):
                self.serve([[package("latest"), *sha_packages(12)], Response(payload)])
                with self.assertRaises(ValueError):
                    self.cleanup()
                self.assertEqual(self.deletions(), [])

    def test_non_object_entries_fail_without_deletion(self):
        for entry in (None, [], "package", 1, True):
            with self.subTest(entry=entry):
                self.assert_invalid_inventory([package("latest"), *sha_packages(12), entry])

    def test_required_string_fields_are_validated_even_for_unrelated_entries(self):
        missing = object()
        for field in ("type", "name", "version"):
            for value in (missing, None, 1, True, [], {}):
                with self.subTest(field=field, value=value):
                    entry = package("unrelated", type="generic", name="other")
                    if value is missing:
                        del entry[field]
                    else:
                        entry[field] = value
                    self.assert_invalid_inventory([package("latest"), *sha_packages(12), entry])

    def test_candidate_id_must_be_an_exact_int(self):
        missing = object()
        for value in (missing, None, True, False, "1", 1.0, [], {}):
            with self.subTest(value=value):
                candidates = sha_packages(12)
                if value is missing:
                    del candidates[-1]["id"]
                else:
                    candidates[-1]["id"] = value
                self.assert_invalid_inventory([package("latest"), *candidates])

    def test_candidate_timestamp_must_be_valid_and_timezone_aware(self):
        missing = object()
        for value in (
            missing, None, True, 123, [], {}, "", "not-a-date",
            "2026-01-01", "2026-01-01T00:00:00", "2026-01-01T00:00:00.123",
            "2026-02-30T00:00:00Z", "2026-01-01T00:00:00+25:00",
        ):
            with self.subTest(value=value):
                candidates = sha_packages(12)
                if value is missing:
                    del candidates[-1]["created_at"]
                else:
                    candidates[-1]["created_at"] = value
                self.assert_invalid_inventory([package("latest"), *candidates])

    def test_duplicate_candidate_tags_and_ids_fail_across_pages(self):
        for field in ("id", "version"):
            with self.subTest(field=field):
                candidates = sha_packages(12)
                duplicate = dict(candidates[-1])
                duplicate["id"] = 999
                duplicate["version"] = "sha-ffffffffffff"
                duplicate[field] = candidates[-1][field]
                self.serve([[package("latest"), *candidates], [duplicate], []])
                with self.assertRaises(ValueError):
                    self.cleanup()
                self.assertEqual(self.deletions(), [])

    def test_later_malformed_candidate_prevents_all_deletions(self):
        self.serve(
            [[package("latest"), *sha_packages(12)], [package("sha-ffffffffffff")], []]
        )
        with self.assertRaises(ValueError):
            self.cleanup()
        self.assertEqual(self.deletions(), [])

    def test_later_invalid_json_prevents_all_deletions(self):
        self.serve(
            [[package("latest"), *sha_packages(12)], Response(raw=b'{"broken":')]
        )
        with self.assertRaises(json.JSONDecodeError):
            self.cleanup()
        self.assertEqual(self.deletions(), [])

    def test_later_get_errors_propagate_without_deletion(self):
        for error in (
            urllib.error.HTTPError(API_URL, 500, "fixture failure", {}, None),
            urllib.error.URLError("fixture connection failure"),
            TimeoutError("fixture timeout"),
        ):
            if isinstance(error, urllib.error.HTTPError):
                self.addCleanup(error.close)
            with self.subTest(error=error):
                self.serve([[package("latest"), *sha_packages(12)], error])
                with self.assertRaises(type(error)) as raised:
                    self.cleanup()
                self.assertIs(raised.exception, error)
                self.assertEqual(self.deletions(), [])

    def test_get_requires_status_200(self):
        for status in (201, 204, 206, 302, 401, 500):
            with self.subTest(status=status):
                self.serve(
                    [[package("latest"), *sha_packages(12)], Response([], status=status)]
                )
                with self.assertRaises((ValueError, RuntimeError, urllib.error.HTTPError)):
                    self.cleanup()
                self.assertEqual(self.deletions(), [])

    def test_delete_requires_status_204_and_stops_on_failure(self):
        for status in (200, 202, 302, 401, 404, 500):
            with self.subTest(status=status):
                self.serve(
                    [[package("latest"), *sha_packages(13)], []],
                    delete_status=status,
                )
                with self.assertRaises((ValueError, RuntimeError, urllib.error.HTTPError)):
                    self.cleanup()
                self.assertEqual(len(self.deletions()), 1)

    def test_delete_errors_propagate_and_stop_further_deletion(self):
        for error in (
            urllib.error.HTTPError(API_URL, 403, "fixture failure", {}, None),
            urllib.error.URLError("fixture connection failure"),
            TimeoutError("fixture timeout"),
        ):
            if isinstance(error, urllib.error.HTTPError):
                self.addCleanup(error.close)
            with self.subTest(error=error):
                self.serve(
                    [[package("latest"), *sha_packages(13)], []],
                    delete_error=error,
                )
                with self.assertRaises(type(error)) as raised:
                    self.cleanup()
                self.assertIs(raised.exception, error)
                self.assertEqual(len(self.deletions()), 1)

    def test_main_reads_environment(self):
        environment = {
            "API_URL": API_URL,
            "REPOSITORY": "Owner/docker-nginx",
            "REGISTRY_TOKEN": TOKEN,
        }
        with mock.patch.dict(os.environ, environment, clear=True):
            with mock.patch.object(self.helper, "cleanup") as cleanup:
                self.helper.main()
        cleanup.assert_called_once_with(API_URL, "Owner/docker-nginx", TOKEN)
        self.urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
