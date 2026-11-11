# Adopting this registry in rank-1/rankone

How rankone's vcpkg builds would switch to this registry, what they gain and
lose, and what has to line up for the prebuilt packages to actually restore.
Written against rankone `master` at `a7efe3e71` (2026-11-01) and this registry
at qtbase 6.11.2#2 and nvidia-cutlass 4.8.1#1 (4.8.0#1 pinned).

**Short version.** Switching the manifest is worth doing on its own: it makes
the GitHub Actions builds compile the same Qt and OpenCV *configuration* the
release SDK ships (headless Qt, runtime OpenSSL, the cut-down OpenCV module set,
hidden symbols), which today they do not. The prebuilts are a smaller, cheaper
win layered on top of the sticky disks: they turn the cold-cache runs (new
preset, evicted disk, baseline bump) from a 30–40 minute rebuild into a restore.
They are not free, though: you need a token, matching compilers, and to bump two
baselines together.

## What rankone builds through vcpkg today

| Workflow | Runner | vcpkg features (from `CMakeLists.txt`) |
| --- | --- | --- |
| `build-sdk.yml` — `sdk-linux-x64-ci`, `-br-ci`, `sdk-linux-arm64-ci` | `blacksmith-16vcpu-ubuntu-2204[-arm]` | `gui`, `numa` |
| `build-sdk-cuda.yml` | `roc-4vcpu-ubuntu-2204` | `cuda`, `numa` (`BR_EMBEDDED=ON`, so no `gui`) |
| `build-sdk-macos.yml` | `roc-10cpu-macos` | `gui` |
| `build-sdk-windows.yaml` | `roc-4vcpu-windows-2022` | `gui`, `cuda` |
| `build-enterprise-search.yml` | `blacksmith-8vcpu-ubuntu-2404[-arm]` | `gui`, `numa`, `prometheus`, `sentry`, `cuda` |

Every one of them caches with `VCPKG_BINARY_SOURCES=clear;default,readwrite`
pointed at a sticky disk (Linux) or the tool cache (macOS, Windows). The
buildbot release builders in `ci/master.cfg` do **not** use vcpkg at all — they
link the Qt 6.8.2, OpenCV 4.8.1 and FFmpeg 7.0.2 trees that `build_qt6.sh`,
`build_opencv.sh` and `share/rankone/install_ffmpeg.sh` produce by hand.

## What the registry changes for rankone

These are behaviour changes, not just plumbing. Each needs a look in review.

| | Today (`ci/vcpkg.json`) | With the registry |
| --- | --- | --- |
| Qt version | 6.11.2 (baseline) | 6.11.2#2 — same Qt, ROC delta on top |
| Qt TLS, Linux | OpenSSL **linked** | `openssl-runtime`: dlopened, like `build_qt6.sh -openssl-runtime` |
| Qt TLS, Windows | OpenSSL | **Schannel** — no OpenSSL in Qt at all |
| Qt TLS, macOS | SecureTransport | unchanged |
| Qt with `gui` | the `gui` edge has no `"default-features": false`, so it pulls Qt's **entire** default set: ICU, libpq, testlib, D-Bus, freetype, harfbuzz, EGL, X11 — **59 packages** on `x64-linux` | `gui`, `sql`, `sql-sqlite`, `widgets`, `xml` and nothing else — **42 packages** |
| Qt Xml | always built | only with `gui` (`build_qt6.sh` uses `-no-feature-xml`) |
| Qt on macOS | dylibs | `.framework` bundles — matches the SDK's own move to frameworks (#4431) and `build_qt6.sh -framework` |
| OpenCV | **4.8.0#22** via override | **4.12.0#9** — see below |
| OpenCV modules | `dnn` and the codecs; every other module is always built, because 4.8.0's port cannot turn them off | `features2d` added; `calib3d`, `flann`, `objdetect`, `photo`, `stitching`, `video` off, as in `build_opencv.sh` |
| OpenCV symbols | default visibility | `-fvisibility=hidden` |
| CUDA (`cuda` feature) | `cudnn` on Linux; #4804 drops it and takes CUTLASS 4.8.0 from a submodule | `nvidia-cutlass` 4.8.0#1 from this registry: upstream's port with cuBLAS and cuDNN off, so no system cuDNN or cuBLAS anywhere |
| FFmpeg | 7.0.2#7 via override | 7.0.2#8: the same FFmpeg plus `nvmpi` and `cuda-llvm` features, and native TLS per platform |
| OpenSSL linkage on macOS, Windows | static | **dynamic**, like Linux — the LGPL-set rule is one list in every triplet |
| Triplets | `ci/vcpkg/*.cmake` (4) | this repo's `triplets/` (10) |

Two of those deserve more than a row.

**OpenCV 4.8.0 → 4.12.0 is a real upgrade, not a rebuild.** The registry's
OpenCV customizations (selectable modules, the Android visibility fix) are
written against the 4.12.0 port, so adopting the registry means adopting 4.12.0.
That moves the GitHub Actions builds *further* from the release builds, which
use 4.8.1, until buildbot moves too. Run the accuracy and benchmark suites
before merging; `dnn` and `imgproc` numerics are where a face pipeline would
notice.

**`intrinsics`, `fs` and `thread` must be listed, or 4.12.0 is quietly slow.**
In 4.8.0#22 they are not port features at all, so they are simply on. Upstream
made them features later, and in the default set — so the moment the version
moves, the `"default-features": false` that `ci/vcpkg.json` already has starts
dropping them. Losing `intrinsics` means `CV_ENABLE_INTRINSICS=OFF`: no
SSE/AVX/NEON paths, no error, just slower. The proposed manifest lists all
three; keep them if you hand-edit it.

## Steps

### 1. Make the feed readable from rank-1 (decide first)

GitHub Packages NuGet feeds are **owner-scoped** and have **no anonymous
access**, even for public packages. This registry publishes to
`https://nuget.pkg.github.com/KOConchobhair/index.json`, so rankone's
`GITHUB_TOKEN` cannot read it. Two ways out:

- **Transfer this repository to `rank-1`** (recommended). Re-run its workflow
  once and the feed becomes `https://nuget.pkg.github.com/rank-1/index.json`;
  rankone then reads it with its own `GITHUB_TOKEN` plus `packages: read`, no
  secrets. Keep it **public**: on a private repo, build-provenance attestations
  need Enterprise Cloud, and the macOS legs bill at 10× minutes.
- Or store a classic PAT with only `read:packages` as a rankone secret. This
  works today, but it ties CI to one person's token.

Without this step, steps 2–3 still give you the configuration changes. Only the
prebuilts are lost.

### 2. Point the manifest at the registry

```bash
git submodule add https://github.com/KOConchobhair/vcpkg-registry ci/vcpkg-registry
cp ci/vcpkg-registry/docs/rankone/vcpkg.json ci/vcpkg.json
git rm -r ci/vcpkg        # the old triplets; the registry's replace them
```

[`docs/rankone/vcpkg.json`](rankone/vcpkg.json) is the current `ci/vcpkg.json`
with exactly these changes:

1. a `registries` entry for this repository, serving `ffmpeg`,
   `jetson-multimedia-api`, `jetson-nvmpi`, `nvidia-cutlass`, `opencv4`, `qtbase`
2. `overlay-triplets` → `./vcpkg-registry/triplets`
3. the `opencv4` and `ffmpeg` overrides deleted — the registry serves 4.12.0#9
   and 7.0.2#8, and an override naming a version the registry lacks does not
   resolve. `protobuf` 3.19.4 stays.
4. opencv4 gains `features2d` (newly a feature) and `fs`, `intrinsics`,
   `thread` — not needed at 4.8.0, where they were not features, but essential
   at 4.12.0, see above
5. the two `qtbase` entries become one, with TLS backends as platform-qualified
   features (adds `schannel`, `openssl-runtime`, `framework`)
6. `"default-features": false` on the `gui` feature's `qtbase` edge, which also
   gains `sql-sqlite` and `xml` (both were coming in through the defaults)
7. ffmpeg gains the `ffmpeg` feature (the CLI, which the SDK installs), and its
   `openssl` feature is limited to Linux and Android, so Apple and Windows keep
   their native TLS
8. a `jetson` feature for `ffmpeg[nvmpi]`; nothing turns it on yet
9. the `cuda` feature is `nvidia-cutlass` and `ffmpeg[nvcodec]`, with `cudnn`
   gone, as in rank-1/rankone#4804, plus an override pinning `nvidia-cutlass`
   to 4.8.0#1. The pin is needed: #4804's vcpkg variant (`79d74ef97`) asks
   `find_package(NvidiaCutlass 4.8.0 EXACT CONFIG)` and links
   `nvidia::cutlass::cutlass`, and the registry's baseline is 4.8.1#1. With the
   registry serving the port, #4804 needs neither its `cutlass` submodule nor
   the `ci/vcpkg-ports` overlay port it carried before `1862285b2`; the
   registry's port is that overlay port (see its `portfile.cmake` header).

Overlay-triplet paths resolve relative to the manifest, so if the submodule goes
elsewhere, change only that one line. Copying `triplets/` into `ci/vcpkg/`
instead of using a submodule also works, but the copy has to stay
byte-identical: triplet file contents are part of every package's ABI hash, so a
one-character drift gives a 0% hit rate with no error.

**Measured:** resolved as committed (public URL, pinned baseline) with the
`gui numa prometheus sentry` features on `x64-linux` and `arm64-osx`, this
manifest yields *exactly* the package set, versions and per-package feature
sets that this registry's CI builds in its desktop flavour. The only difference
is the `amqpcpp` and `libuv` the test manifest carries to prove upstream
fallback.

### 3. Layer the feed under the sticky disk

Sources are consulted in order, so the sticky disk stays first and the feed only
answers what the disk does not have. `read`, not `readwrite`: rankone's
compilers differ from the publishing CI's in ways nobody is checking, so it
should not write into the shared feed.

```yaml
    permissions:
      contents: read
      packages: read          # with the repository under rank-1 (step 1)

      - name: Set up vcpkg
        uses: lukka/run-vcpkg@v11

      - name: Authenticate vcpkg binary cache (read-only)
        shell: bash
        env:
          FEED: https://nuget.pkg.github.com/rank-1/index.json
          TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          NUGET="$("$VCPKG_ROOT/vcpkg" fetch nuget | tail -n1)"
          nu() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) "$NUGET" "$@";; *) mono "$NUGET" "$@";; esac; }
          nu sources add -Source "$FEED" -StorePasswordInClearText -Name roc \
             -UserName "${{ github.repository_owner }}" -Password "$TOKEN"

      - name: Run CMake preset
        uses: lukka/run-cmake@v10
        with:
          configurePreset: '${{ matrix.preset }}'
        env:
          VCPKG_BINARY_SOURCES: "clear;files,${{ github.workspace }}/.vcpkg-cache,readwrite;nuget,https://nuget.pkg.github.com/rank-1/index.json,read"
          VCPKG_FORCE_DOWNLOADED_BINARIES: "1"
```

`nuget.exe` needs `mono` off Windows. `build-sdk.yml` installs `mono-devel` on
the x64 leg only, so the arm64 leg needs `sudo apt-get install -y mono-complete`
first.

### 4. Measure the hit rate

vcpkg logs `Restored N package(s) from <source>` per source. On the first run
after adopting, empty the sticky disk (or use a fresh key) so the feed is the only
warm source, and read that line. 40 or so restored packages on a Linux leg means
it is working; zero means one of the ABI inputs below differs. A miss is silent
and harmless — vcpkg just builds — which is why this needs to be checked, not
assumed.

## What has to match for a prebuilt to restore

vcpkg keys every package on an ABI hash. It does not degrade gracefully: one
differing input means a clean 0% hit rate and no error.

| Input | Status for rankone |
| --- | --- |
| Port versions and feature sets | **Matches**, measured — see step 2 |
| Triplet file contents | Matches once `overlay-triplets` points at this repo's `triplets/` |
| vcpkg tool scripts | Matches while `builtin-baseline` equals this registry's `VCPKG_BASELINE`. `lukka/run-vcpkg@v11` with no inputs checks out the manifest's `builtin-baseline`, and `scripts/` is part of every hash. **Both are `2cfff9c` today, and must be bumped together** |
| Compiler | **Unverified.** The hash includes a SHA-1 of the compiler *binaries* (`scripts/detect_compiler/CMakeLists.txt`), not just the version. The publisher builds on GitHub's `ubuntu-22.04`, `ubuntu-22.04-arm`, `macos-15` and `windows-2022` |

Per rankone runner, the compiler row works out like this:

- **Blacksmith `ubuntu-2204` (x64 and arm):** plausible. Both images take gcc 11
  from Ubuntu's jammy archive; if the package builds are the same, the binaries
  are identical. Step 4 answers it.
- **`roc-10cpu-macos`, `roc-4vcpu-windows-2022`, `roc-4vcpu-ubuntu-2204`:** hits
  only if these run the same image as the publishing legs — that is, if they are
  GitHub-hosted larger runners on `macos-15` / `windows-2022` / `ubuntu-22.04`.
  On macOS the hash follows the Xcode that `xcrun` resolves to, so a different
  Xcode is a guaranteed miss.
- **Blacksmith `ubuntu-2404` (enterprise-search):** **no hits** — gcc 13 against
  the publisher's gcc 11. That would need 24.04 legs here (see further work).
- **CUDA:** `nvidia-cutlass`, the `cuda` port and `ffmpeg[nvcodec]` are
  prebuilt on `x64-windows` (desktop flavour, `gui cuda`), and on `x64-linux`
  and `arm64-linux` in a `cuda` flavour (`cuda numa`, as `build-sdk-cuda.yml`).
  The publishing legs install CUDA with the same `Jimver/cuda-toolkit` steps
  rankone uses. The toolkit is not part of either port's ABI hash, so its
  version does not matter. Linux CUDA is its own flavour, not added to the
  desktop one, because `cuda` changes `ffmpeg`'s feature set, and
  `build-sdk.yml`'s non-CUDA builds would then never hit `ffmpeg`.

## Pros and cons

**For**

- **Parity with what ships.** CI compiles the release configuration of Qt,
  OpenCV and FFmpeg, not vcpkg's desktop defaults. The `gui` trap alone currently
  puts ICU, libpq, X11 and the rest of Qt's defaults into every Linux CI build.
- **A much smaller Linux CI graph.** 42 packages instead of 59 with `gui` on —
  the difference is everything the `gui` trap drags in (ICU, libpq, D-Bus, X11).
- **One definition of the third-party stack.** The same ports could replace
  `build_qt6.sh`, `build_opencv.sh` and the S3 FFmpeg bundles on the buildbot
  workers — which is what the parity work in this registry was for.
- **Cold runs get cheap.** A new preset, a new runner type, an evicted or
  corrupted sticky disk, and above all a **baseline bump** (which changes every
  hash at once) restore from the feed instead of spending 30–40 minutes per leg.
  The disks are per preset, so `sdk-linux-x64-ci` and `sdk-linux-x64-br-ci` each
  pay that separately today; the feed is shared.
- **Attested binaries.** Every leg's installed tree is also published as a
  tarball with SLSA provenance (`gh attestation verify`), downloadable with no
  token — handy for reproducing a CI build locally.

**Against**

- **"Can't hurt" is nearly, not entirely, true.** On a hit it is free; on a miss
  it costs one feed query per package (seconds). The real costs are the setup
  (token, `mono`, one more step per workflow) and the expectation that it is
  working when nothing checks that.
- **Lock-step baselines.** Every rankone baseline bump needs this registry
  resynced first — the bump to `2cfff9c` is exactly what forced the qtbase
  6.11.1 → 6.11.2 resync here. Until it is, prebuilts stop matching, and a stale
  registry can hand rankone an older Qt than the baseline would.
- **Runner image churn re-keys the cache.** The compiler is hashed by its bytes,
  so when GitHub retires an image the prebuilts for it stop matching anything
  until both sides move. It already happened once: `macos-14` was retired on
  2026-11-02, mid-rebuild, and the macOS legs moved to `macos-15`. `ubuntu-22.04`
  will go the same way, and when it does the Blacksmith 22.04 legs and this
  registry's Linux legs have to move together.
- **Owning ports.** A registry port replaces upstream's entirely. Upstream fixes
  to `qtbase`, `opencv4` and `ffmpeg` arrive only when someone resyncs. The ROC
  delta is kept small and additive (about 50 lines per port, in `# ROC:` blocks)
  to make that cheap, but it is still a job.
- **OpenCV jumps to 4.12.0**, widening the gap to the release builds' 4.8.1
  until buildbot follows.
- **Windows packaging changes.** OpenSSL becomes a DLL, and Qt uses Schannel. The
  Windows SDK package must ship `libssl-3-x64.dll` and `libcrypto-3-x64.dll` if
  anything in the SDK links OpenSSL directly.
- **Bus factor.** The feed and the registry currently live in one personal
  account. Step 1 fixes that.
- **The Ubuntu 20.04 worker cannot use any of it.** Linux binaries built on 22.04
  need glibc 2.35, so the new `Linux-ARM64-Legacy` buildbot (20.04, glibc 2.31)
  cannot consume these artifacts, prebuilt or not.

## Further work and optimizations

Roughly in order of value for effort:

1. **Transfer the registry to `rank-1`** (step 1). Unblocks token-free reads and
   removes the single-owner risk.
2. **Adopt the manifest in rankone** behind a PR, run the accuracy and benchmark
   suites against OpenCV 4.12.0, and measure the hit rate on the Blacksmith 22.04
   legs (step 4).
3. **Replace the S3 FFmpeg bundles.** `CMakeLists.txt` downloads hand-built FFmpeg
   7.0.2 bundles (CUDA, Jetson nvmpi, openh264, openssl; frameworks on macOS)
   from `s3://rankone/dependencies`. This registry's `ffmpeg[nvcodec,cuda-llvm,nvmpi]`
   is the same FFmpeg, built reproducibly and redistributably (`cuda-llvm`, not
   the non-free `cuda-nvcc`). The macOS framework layout is the one gap.
4. **Publish where rankone already authenticates.** vcpkg can also cache to S3
   (`x-aws,s3://…,readwrite`). `rankone` already uses AWS from CI and buildbot;
   an S3 cache would need no PAT and no `mono`, and could serve the buildbot
   workers too. It needs an OIDC role that trusts this repository's workflow.
5. **Ubuntu 24.04 legs** for `build-enterprise-search.yml`, if its cold builds
   matter. Two more matrix entries; no port changes expected.
6. **Move buildbot onto vcpkg plus the registry**, retiring `build_qt6.sh`,
   `build_opencv.sh` and the 6.8.2/4.8.1 hand builds. That is the end state the
   parity work points at, and the moment CI and release stop differing.
7. **Prune the feed.** GitHub Packages has no eviction, and every baseline bump
   adds a full set of packages per triplet. A scheduled job that deletes package
   versions older than the current baseline's would keep it bounded.
8. **Resync opencv4 to upstream 4.14.0.** Upstream moved on at `2cfff9c`; the
   registry stays on 4.12.0 for now because rankone overrides OpenCV anyway and
   the module-dependency declarations would have to be re-derived from 4.14.0's
   `ocv_define_module` calls. Worth doing together with step 2's accuracy runs,
   so OpenCV moves once rather than twice.
