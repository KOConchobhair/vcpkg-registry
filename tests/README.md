# Registry build tests

Builds `tests/vcpkg.json` — the consumer manifest — against this registry, using
this registry's own overlay triplets.

`tests/run.sh` does the work and takes its paths from the environment, so one
implementation serves both entry points:

| | Where | Use it for |
| --- | --- | --- |
| `.github/workflows/ports.yml` | GitHub Actions, a native runner per triplet | the gate on every push, and every platform but arm64-linux |
| `./tests/build.sh` | Ubuntu 22.04 containers under colima | **arm64-linux**, and local iteration |

Every mode is **vcpkg manifest mode** — an install driven by `tests/vcpkg.json`.
There is no classic-mode path here and none is wanted.

```
./tests/build.sh arm64            # consumer: build through the registry - the test
./tests/build.sh arm64 resolve    # the same, resolution only, no compiling
./tests/build.sh arm64 overlay    # dev loop: working tree via --overlay-ports
./tests/build.sh arm64 verify     # re-check an existing install without rebuilding
```

- **`consumer`** (the default) resolves through the manifest's own
  `vcpkg-configuration` — this registry over git, the builtin registry at
  `builtin-baseline` for everything else — then builds and verifies. This is the
  only mode that exercises `versions/`, and it is what CI runs.
- **`resolve`** is the same path, stopping after resolution. Use it to check a
  feature graph or a freshly recorded version in seconds.
- **`overlay`** swaps in `--overlay-ports` so it acts on the working tree with no
  commit needed. Convenient while editing a port, but it bypasses `versions/`
  entirely, so it proves nothing about the registry.
- `consumer` and `resolve` read the **committed** tree — commit, and record the
  version with `x-add-version`, before running them.
- **`verify`** checks the install has the shape the manifest asked for: the
  opencv4 modules that should exist do and the trimmed ones don't, opencv is built
  with hidden visibility, the Qt modules likewise, and the OpenSSL TLS plugin is
  in the mode the manifest selected — it reads `vcpkg.json` to decide whether to
  expect `linked` or `runtime`, so it stays a real check either way. It also pins
  the one known parity gap, `Qt6Xml`, as *expected present*, so an upstream change
  there surfaces as a test result rather than a surprise.

## In CI

One job per triplet, all running `consumer`: the full install through the git
registry plus `verify.sh`. All four runner images are free for public repositories.

| Triplet | Runner | Notes |
| ------- | ------ | ----- |
| `x64-linux` | `ubuntu-22.04` | |
| `arm64-linux` | `ubuntu-22.04-arm` | also covered locally |
| `arm64-osx` | `macos-14` | prerequisites via `brew` |
| `x64-windows` | `windows-2022` | Git Bash + `cygpath`; MSVC preinstalled |

`fail-fast: false`, so one platform breaking still reports the others. There is no
separate resolve-only job — resolution happens before any compiling, so a broken
feature graph still fails within a minute or two.

`verify.sh` adapts per platform: file naming (`.so`/`.dylib`/`.dll`), inspection
tooling (`readelf`/`otool`, neither on Windows), and the expected TLS backend
plugin — `qopensslbackend`, `qsecuretransportbackend`, `qschannelbackend`. Checks
that cannot be expressed on a platform print `skip` and are counted, rather than
silently passing.

**Only `arm64-linux` has been run.** The macOS and Windows legs are written but
unexercised — nothing here can build them — so expect first-run fixups there.

System packages come from `apt-packages.txt`, the same list `Dockerfile` uses, so
the container and the runners cannot drift. `actions/cache` holds the vcpkg binary
cache and downloads, keyed on `ports/**`, `triplets/**` and `tests/vcpkg.json` —
everything that feeds an ABI hash — with `restore-keys` seeding from the last run.

**Build x64 in CI, not locally on Apple silicon.** x64 there runs under Rosetta,
which intermittently leaves cmake asleep in `ep_poll` waiting on a child that
already exited — not slow, stopped. Nothing in the ports causes it: the same build
is clean on arm64, and a native x86_64 runner has no such problem.
`./tests/build.sh x64` is still there and works on real x86_64 hardware.

## Locally

colima, with enough disk for the buildtrees:

```
colima status
```

Run one build at a time. `VCPKG_MAX_CONCURRENCY` defaults to 6 and can be lowered
if the VM runs short of memory during the qtbase or opencv link steps.

## Layout

- `vcpkg.json` — **the consumer manifest**, and the end state for
  `rankone-ffmpeg-jetson/ci/vcpkg.json`: rankone's real dependency set, plus
  `builtin-baseline` and an embedded `vcpkg-configuration` naming this registry
  over git. Self-contained; there is no `vcpkg-configuration.json`. See "Changes
  ci/vcpkg.json needs" in the top-level README.

  The committed file names this registry by its public URL and a pinned baseline,
  which is what a consumer copies. `run.sh` redirects those two fields to the local
  checkout at `HEAD`, so a run tests the commit in front of it rather than whatever
  was last pushed. `USE_MANIFEST_AS_IS=1` runs the file verbatim instead, which
  works once that baseline has been pushed. Nothing else in the file is touched.

  Because `overlay-triplets` is `../triplets`, resolved relative to the manifest,
  `run.sh` stages `tests/` and `triplets/` together rather than copying the manifest
  somewhere flat.
- `apt-packages.txt` — the system package list. Deliberately no cmake or ninja:
  Ubuntu 22.04's cmake is 3.22 and vcpkg at this baseline needs 4.2+ for
  `string(JSON ... STRING_ENCODE)`. vcpkg carries cmake 4.4.0 for both
  linux-aarch64 and linux-x86_64, so it fetches its own. Do not set
  `VCPKG_FORCE_SYSTEM_BINARIES` — that pins it to the too-old one.
- `Dockerfile` — those packages baked into an image layer, so repeat local runs
  skip apt entirely.
- `run.sh` — bootstraps vcpkg at the pinned baseline, installs the manifest,
  verifies. Paths from `REGISTRY`, `WORK`, `VCPKG_DOWNLOADS`,
  `VCPKG_DEFAULT_BINARY_CACHE`.
- `verify.sh` — the assertions; `verify.sh <triplet> [installed-root]`.
- `build.sh` — local driver: builds the image, wires up the mounts, picks the
  platform, and sets the paths `run.sh` expects.

## Why the mounts look the way they do

Only `/Users` is visible inside the colima VM, so the registry is bind-mounted
from there. Everything vcpkg writes — buildtrees, packages, downloads, binary
cache — lives in named volumes on the VM's own ext4 instead. That keeps the build
off the case-insensitive macOS filesystem, which the `jetson-*` ports require and
which is much faster than virtiofs regardless.

State persists in the `test-work-{arm64,x64}`, `test-resolve-{arm64,x64}`,
`test-downloads`, `test-tools-{arm64,x64}` and `test-cache` volumes, so a re-run
resumes rather than restarting. To start clean:

```
docker volume ls -q --filter name=test- | xargs docker volume rm
```

Source tarballs are shared between architectures; the tools vcpkg downloads for
itself are not. vcpkg names its tool directories by version and platform but not
by architecture — `cmake-4.4.0-linux` holds either the aarch64 or the x86_64 tree
— so one shared downloads volume would let whichever arch ran first satisfy the
other's cmake and hand it a binary it cannot execute. Hence the per-arch mount
over `/downloads/tools`.
