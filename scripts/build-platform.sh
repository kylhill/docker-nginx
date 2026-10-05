#!/usr/bin/env bash
set -Eeuo pipefail

# Build one CI platform. Export and cache options belong to the calling workflow.
# Print the immutable digest; Buildx progress goes to stderr.
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform="${1:?usage: build-platform.sh PLATFORM METADATA_FILE [buildx options...]}"
metadata="${2:?metadata file is required}"
shift 2

attestations=()
if [ -n "${SYFT_SCANNER_IMAGE:-}" ]; then
    attestations=(--provenance=mode=max --sbom="generator=${SYFT_SCANNER_IMAGE}")
fi
docker buildx build --platform "${platform}" --pull \
    "${attestations[@]}" --metadata-file "${metadata}" "$@" "${REPOSITORY_ROOT}" >&2
python3 - "${metadata}" <<'PYTHON'
import json
import re
import sys

with open(sys.argv[1]) as source:
    digest = json.load(source)["containerimage.digest"]
if not isinstance(digest, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
    raise SystemExit("Buildx metadata did not contain a valid image digest")
print(digest)
PYTHON
