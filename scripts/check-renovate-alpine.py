#!/usr/bin/env python3
"""Reject Renovate APK lookups against a different Alpine base branch."""

import json
from pathlib import Path
import re
import sys
from urllib.parse import parse_qs, urlparse


def check(root):
    dockerfile = (root / "Dockerfile").read_text()
    bases = re.findall(
        r"^FROM\s+(?:docker\.io/library/)?alpine:(\d+\.\d+)(?:\.\d+)?(?:@\S+)?\s*$",
        dockerfile, re.MULTILINE,
    )
    if len(bases) != 1:
        raise ValueError("Expected one versioned Alpine base in Dockerfile")
    expected = "v" + bases[0]
    config = json.loads((root / "renovate.json").read_text())
    urls = [
        url
        for rule in config.get("packageRules", [])
        if "apk" in rule.get("matchDatasources", [])
        for url in rule.get("registryUrls", [])
    ]
    if not urls:
        raise ValueError("Missing Renovate APK registryUrls")
    for url in urls:
        branches = parse_qs(urlparse(url).query).get("branch", [])
        if branches != [expected]:
            raise ValueError(
                f"Renovate APK registry must use branch={expected} to match Dockerfile; "
                f"found {url}"
            )


if __name__ == "__main__":
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    try:
        check(root)
    except (ValueError, OSError) as error:
        sys.exit(str(error))
    print("Renovate APK registry matches the Alpine base branch.")
