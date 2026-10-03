# CI and publishing

The Forgejo `docker-publish.yml` workflow runs on relevant pushes to `main` or
manual dispatch. A single `oci-build` job requires a native arm64 Docker daemon
and builds and pushes both platform images by digest, but never loads or runs
the amd64 image. It pulls the arm64 digest and runs the full native suite before
assigning `latest` and `sha-<12-character SHA>` tags to a manifest containing
those digests at `git.tacomafia.net/<owner>/<repository>`. After successful
publishing, retention keeps the newest 10 matching
`sha-[a-f0-9]{12}` tags for the lowercase repository image, preserving `latest`,
all nonmatching tags/digests, and other packages. Cleanup errors fail the job.
Actual disk reclamation depends on Forgejo server cleanup/garbage collection,
including removal of dangling container digests.

The job explicitly uses the current Node.js LTS Alpine line, providing Node.js
for `actions/checkout`. Before checkout, a `sh` step installs Bash, Docker CLI
and Buildx, Git, OpenSSL, Python 3, and ShellCheck. Offline script and retention
checks run before build setup. The runner must provide Docker daemon
access and support for building both architectures (including preconfigured
QEMU/binfmt emulation for non-native builds). Test fixtures are transferred
through the Docker API, not host bind mounts.
The job creates a per-run Docker context from the runner's connection settings,
including TLS certificates, and passes it explicitly to Buildx. The builder and
context are removed afterward only if their creation succeeded. PR builds use
`docker-nginx-pr`; publishing uses `docker-nginx-publish`. Both recreate their
builder with a stable node name and remove it with `--keep-state`, retaining
separate Docker state volumes inside the runner's persistent rootless Docker
storage. Per-run contexts remain ephemeral. The `oci-build` runner has capacity
one, so jobs using these fixed names run sequentially; retain this serialization
if runner capacity changes.

`.forgejo/buildkitd.toml` enables BuildKit garbage collection with a 15 GB
usage target per builder, a 2 GB retained-cache floor, and a 10 GB free-space
target. These are GC thresholds, not filesystem quotas. The Docker daemon's
builder GC configuration does not apply to these BuildKit containers. Local
PR cache exports and publishing's registry caches remain available as fallbacks;
publishing does not import PR state. Removing a builder preserves its state,
but removing its Docker volume or the runner's Docker data directory clears it.
Set the repository's `REGISTRY_TOKEN` Actions secret to
a token with `write:package` scope and write permissions for the package owner.

The tagged manifest uses the already-built platform digests. Cache exports run
separately to avoid concurrent blob-upload conflicts in Forgejo. GitHub provides
the complementary native amd64 smoke and integration coverage while only building arm64. After
publishing, each registry retains its newest 10 short-SHA releases.
