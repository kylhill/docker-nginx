# CI and publishing

The Forgejo `docker-publish.yml` workflow runs on relevant pushes to `main` or
manual dispatch. A single `oci-build` job requires a native arm64 Docker daemon
and builds and pushes both platform images by digest, but never loads or runs
the amd64 image. It pulls the arm64 digest and runs the full native suite before
assigning `latest` and `sha-<12-character SHA>` tags to a manifest containing
those digests at `git.tacomafia.net/<owner>/<repository>`.

Forgejo retention is managed by the package owner's
[built-in cleanup rule](https://forgejo.org/docs/v15.0/user/packages/#cleanup-rules),
not by the publishing job. Before using this workflow, configure the following
rule in the `kylhill` account's Packages settings on `git.tacomafia.net` and
review its preview:

| Setting | Value |
| --- | --- |
| Enabled | Yes |
| Type | Container |
| Apply pattern to full package name | Yes |
| Keep the most recent | 10 |
| Keep versions matching | Empty (`latest` is always preserved) |
| Remove versions older than | 0 days |
| Remove versions matching | `docker-nginx/sha-[a-f0-9]{12}` |

Only matching SHA tags for this package are eligible for deletion. Other
packages and nonmatching versions, including existing `buildcache-*` tags and
digest versions, are untouched. Forgejo adds regex anchors automatically.
The count applies to all versions of the package before the removal pattern
is evaluated, so this is not an exact ten-SHA-release policy. Cleanup runs
periodically, independently of publishing; failures no longer fail CI.
Until the account rule is configured, this workflow performs no Forgejo
retention. Actual disk reclamation also depends on server blob garbage collection;
this rule does not remove dangling digest versions.

The job uses a pinned Node.js Alpine image managed by Renovate, providing Node.js
for `actions/checkout`. Before checkout, a `sh` step installs Bash, Docker CLI
and Buildx, Git, OpenSSL, Python 3, and ShellCheck. Offline script checks run
before build setup. The runner must provide Docker daemon
access and support for building both architectures (including preconfigured
QEMU/binfmt emulation for non-native builds). Test fixtures are transferred
through the Docker API, not host bind mounts.
The job creates a per-run Docker context from the runner's connection settings,
including TLS certificates, and passes it explicitly to Buildx. The builder and
context are removed afterward only if their creation succeeded. PR builds use
`docker-nginx-pr`; publishing uses `docker-nginx-publish`. Both recreate their
builder with a stable node name and remove it with `--keep-state`, retaining
separate Docker state volumes inside the runner's persistent rootless Docker
storage. This persistent state is the sole build cache; no local or registry
cache exports are used. Per-run contexts remain ephemeral. The `oci-build`
runner has capacity one, so jobs using these fixed names run sequentially; retain this serialization
if runner capacity changes.

`.forgejo/buildkitd.toml` enables BuildKit garbage collection with a 15 GB
usage target per builder, a 2 GB retained-cache floor, and a 10 GB free-space
target. These are GC thresholds, not filesystem quotas. The Docker daemon's
builder GC configuration does not apply to these BuildKit containers.
Publishing does not import PR state. Removing a builder preserves its state,
but removing its Docker volume or the runner's Docker data directory clears it
and causes a cold build. Caches cannot be restored on a replacement runner.
Set the repository's `REGISTRY_TOKEN` Actions secret to
a token with `write:package` scope and write permissions for the package owner.

The tagged manifest uses the already-built platform digests. GitHub provides
the complementary native amd64 smoke and integration coverage while only
building arm64. After publishing, GitHub retains its newest 10 short-SHA releases through its CI job;
Forgejo uses the periodic account rule above.

Both publishing workflows use `scripts/build-platform.sh` for platform builds
and digest extraction. The workflows retain their own cache and export options;
the helper writes Buildx progress to stderr and prints the digest to stdout.
When `SYFT_SCANNER_IMAGE` is set, it enables the shared provenance and SBOM
options; PR builds omit that publishing-only environment variable.
Published images are pulled and tested directly by digest, using
`verify-integration.sh` on arm64 in Forgejo and amd64 in GitHub. Forgejo PR
validation loads its native image locally; the cache-only amd64 build remains
an explicit Buildx command. These commands add no runtime emulation setup.
