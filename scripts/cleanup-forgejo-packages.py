"""Retain the ten newest SHA tags for one Forgejo container package."""

import datetime
import json
import os
import re
import urllib.parse
import urllib.request


KEEP = 10
SHA_TAG = re.compile(r"sha-[a-f0-9]{12}")


def fetch_packages(api_url, owner, name, token):
    packages = []
    page = 1
    while True:
        query = urllib.parse.urlencode(
            {"type": "container", "q": name, "page": page, "limit": 50}
        )
        url = f"{api_url}/packages/{urllib.parse.quote(owner, safe='')}?{query}"
        request = urllib.request.Request(url, headers={"Authorization": f"token {token}"})
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status != 200:
                raise ValueError(f"Package listing returned HTTP {response.status}")
            entries = json.load(response)
        if not isinstance(entries, list):
            raise ValueError("Package listing must be an array")
        if not entries:
            return packages
        packages.extend(entries)
        # Forgejo may cap page size below the requested limit.
        page += 1


def select_deletions(packages, name):
    inventory = []
    for package in packages:
        if not isinstance(package, dict) or any(
            not isinstance(package.get(field), str)
            for field in ("type", "name", "version")
        ):
            raise ValueError("Package entries must have string type, name and version")
        if package["type"] == "container" and package["name"] == name:
            inventory.append(package)

    if sum(package["version"] == "latest" for package in inventory) != 1:
        raise ValueError("Expected exactly one latest version for the published package")

    candidates = []
    tags = set()
    ids = set()
    for package in inventory:
        tag = package["version"]
        if not SHA_TAG.fullmatch(tag):
            continue
        package_id = package.get("id")
        timestamp = package.get("created_at")
        if type(package_id) is not int or not isinstance(timestamp, str):
            raise ValueError(f"Invalid id or created_at for {tag}")
        if tag in tags or package_id in ids:
            raise ValueError(f"Duplicate SHA tag or package id for {tag}")
        created_at = datetime.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        if created_at.utcoffset() is None:
            raise ValueError(f"created_at must include a timezone for {tag}")
        tags.add(tag)
        ids.add(package_id)
        candidates.append((created_at, package_id, package))

    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return [package for _, _, package in candidates[KEEP:]]


def cleanup(api_url, repository, token):
    owner, name = repository.lower().split("/", 1)
    packages = fetch_packages(api_url, owner, name, token)
    deletions = select_deletions(packages, name)
    print(f"Deleting {len(deletions)} SHA tags; retaining up to {KEEP} newest SHA tags.")
    for package in deletions:
        tag = package["version"]
        url = (
            f"{api_url}/packages/{urllib.parse.quote(owner, safe='')}"
            f"/container/{urllib.parse.quote(name, safe='')}"
            f"/{urllib.parse.quote(tag, safe='')}"
        )
        request = urllib.request.Request(
            url, headers={"Authorization": f"token {token}"}, method="DELETE"
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status != 204:
                raise ValueError(f"Deleting {tag} returned HTTP {response.status}")
        print(f"Deleted {tag}", flush=True)
    print(f"Deleted {len(deletions)} SHA tags; latest and all nonmatching versions preserved.")


def main():
    cleanup(os.environ["API_URL"], os.environ["REPOSITORY"], os.environ["REGISTRY_TOKEN"])


if __name__ == "__main__":
    main()
