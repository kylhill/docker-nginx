#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shopt -s nullglob
scripts=("${REPOSITORY_ROOT}"/scripts/*.sh)
for script in "${scripts[@]}" "${REPOSITORY_ROOT}"/tests/fixtures/*.env; do
    bash -n "${script}"
done
if command -v shellcheck >/dev/null; then
    shellcheck --external-sources --source-path=SCRIPTDIR "${scripts[@]}"
else
    echo "ShellCheck unavailable; Bash syntax checks only."
fi
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
    -s "${REPOSITORY_ROOT}/tests" -p 'test_*.py' -v
git -C "${REPOSITORY_ROOT}" diff --check
echo "Offline verification passed."
