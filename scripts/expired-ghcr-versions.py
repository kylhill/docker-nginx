#!/usr/bin/env python3
"""Select expired versions from gh api --paginate --slurp JSON on stdin."""
import json
import re
import sys


def expired_versions(pages, keep=10):
    candidates = []
    for page in pages:
        for version in page:
            tags = version["metadata"]["container"]["tags"]
            if tags and all(re.fullmatch(r"sha-[a-f0-9]{12}", tag) for tag in tags):
                identifier = version["id"]
                if type(identifier) is not int or identifier <= 0:
                    raise ValueError("Invalid package version ID")
                candidates.append(version)
    candidates.sort(key=lambda v: (v["created_at"], v["id"]), reverse=True)
    return [version["id"] for version in candidates[keep:]]


if __name__ == "__main__":
    print("\n".join(map(str, expired_versions(json.load(sys.stdin)))) )
