# KOConchobhair vcpkg Registry

A [git registry](https://learn.microsoft.com/en-us/vcpkg/concepts/registries) holding
the ports the ROC SDK needs to customize, plus the Jetson-only ports upstream
does not carry at all, plus the overlay triplets that go with them.

## Ports

| Port | Upstream | Why it is here |
| ---- | -------- | -------------- |
| `qtbase` | 6.11.1#1 → **#2** | Adds the missing `schannel` TLS backend for Windows, and an `openssl-runtime` feature so Qt dlopens libssl instead of linking it |
| `opencv4` | 4.12.0#7 → **#8** | Makes six always-on modules selectable, so the module set can be cut down |
| `ffmpeg` | 7.0.2#7 → **#8** | Adds `nvmpi` and `cuda-llvm` features |
| `jetson-multimedia-api` | — | NVIDIA Jetson Linux Multimedia API (L4T 36.4 / JetPack 6) headers and helper sources |
| `jetson-nvmpi` | — | `libnvmpi`, the library behind FFmpeg's `*_nvmpi` codecs on Jetson |

## Relationship to microsoft/vcpkg

vcpkg has no way to extend another registry's port — a registry port *replaces*
a port, so customizing one means owning the whole recipe. To keep that
maintainable, upstream is a real git remote:

```
git remote add upstream https://github.com/microsoft/vcpkg.git
git config remote.upstream.tagOpt --no-tags
git fetch --filter=blob:none upstream master
```

`--filter=blob:none` keeps the whole commit and tree history — enough to diff,
merge and blame against upstream — while fetching file contents only on demand.
It costs about 50 MB rather than several hundred.

`qtbase` and `opencv4` were vendored in a **pure vendor commit** (`e0ad9522b`),
byte-for-byte from upstream `3c5d90a305ff00ca841f085a74a7ce74ee777dee` — the
`builtin-baseline` the consuming project pins. Local changes came in the commits
after it. That split is the point: the vendor commit is the merge base that makes
every later comparison a clean three-way diff.

### Seeing the local delta

```
git diff e0ad9522b HEAD -- ports/opencv4 ports/qtbase
```

Around 100 added lines across four files, and every change is **purely
additive**: new features, in the style each port already uses. No
`default-features` list is touched, no existing feature changes meaning, and
nothing behaves differently for anyone who does not ask for the new features. All
of it is proposable upstream as-is.

Changes to `.cmake` files sit inside `# ROC: begin` / `# ROC: end` blocks. The
`vcpkg.json` additions are not marked, because JSON has no comments — the diff
above is the record.

### Resyncing to a newer upstream

```
git fetch --filter=blob:none upstream master
git checkout <newer-sha> -- ports/qtbase          # replace the port wholesale
git diff <vendor-sha> <old-head> -- ports/qtbase  # the ROC delta to re-apply
```

Then re-apply the `ROC:` blocks and the `vcpkg.json` feature additions, bump
`port-version`, and re-record the version (see below). For `ffmpeg`, also point
`ROC_NVMPI_PATCH` at the matching `ffmpegX.Y_nvmpi.patch` — jetson-ffmpeg ships
6.0, 6.1, 7.0, 7.1, 8.0 and 8.1.

### Proposing a change upstream

The vendored ports keep upstream's directory layout, so a port directory drops
straight into a vcpkg checkout. Copy the port into a fork of microsoft/vcpkg,
run `vcpkg x-add-version <port>` there, and open the PR. If it lands, the next resync deletes the corresponding `ROC:` block
instead of carrying it forever.

## `default-features: false` has to be on *every* edge

Both ports get their reduced configuration the same way: the consumer says
`"default-features": false` and lists what it wants. Neither port's
`default-features` is modified — that keeps the local delta additive and
upstream-proposable.

There is one trap, and `ci/vcpkg.json` is currently in it. vcpkg **unions**
feature requests across the whole dependency graph, and defaults are suppressed
only on the edges that actually say `"default-features": false`. That manifest has
two `qtbase` edges. The base one opts out; the one under its `gui` feature does
not:

```json
"features": {
  "gui": {
    "dependencies": [
      { "name": "qtbase", "features": ["gui", "sql", "widgets"] }
    ]
  }
}
```

Measured, against this registry's `qtbase`:

| consumer manifest | resolved `qtbase` |
| --- | --- |
| base edge only | `[core, doubleconversion, network]` |
| `gui` enabled, no `default-features: false` on its edge | `[async-io, brotli, concurrent, core, dnslookup, doubleconversion, future, gui, network, openssl, pcre2, thread, widgets, zstd]` |
| `gui` enabled, **with** `default-features: false` on its edge | `[…base…, gui, sql, sql-sqlite, widgets]` and nothing more |

Against *upstream* defaults the middle row is far worse than it looks — that is
where `icu`, `libpq` (via `sql-psql`), `testlib`, `freetype`, `harfbuzz` and the
whole X11 stack come from. So enabling `gui` today does not add a GUI to a
headless Qt; it silently discards the entire headless configuration.

`opencv4` never had this problem because it has only one edge, and that edge opts
out. It is not that opencv4 needed less customization — it is that nothing in the
manifest re-requests it.

`tests/vcpkg.json` is the corrected shape, and the third row above is a real
measurement of it.

## TLS backends

Qt 6 has three, one per platform, and the port now exposes all three:

| Platform | Feature | Effect |
| -------- | ------- | ------ |
| Linux | `openssl` + **`openssl-runtime`** | `INPUT_openssl=runtime` — dlopens libssl/libcrypto, links neither |
| macOS, iOS | `securetransport` | Apple's native stack, no OpenSSL |
| Windows | **`schannel`** | Windows' native stack, no OpenSSL |

Each platform gets its native backend, and on Linux the OpenSSL backend is resolved
at run time rather than linked — which is what `ci/build_qt6.sh` line 19 does with
`-openssl-runtime`.

`schannel` is new. Qt has always had the backend —
`qt_feature("schannel" ... CONDITION WIN32)` in `src/network/configure.cmake` —
but the vcpkg port never exposed it, so the only way to get TLS on Windows was to
link OpenSSL.

It is a **feature only**, not a default. Adding
`{"name": "schannel", "platform": "windows"}` to `default-features` would mirror
the `securetransport`-on-`ios` entry upstream already has, and it was tried — but
it buys a consumer using `"default-features": false` precisely nothing, since that
suppresses defaults by design. Weighed against a permanent conflict surface in the
one array most likely to move upstream, it is not worth it. The same argument
applies to widening `securetransport` to `ios | osx`: either both or neither, and
neither is the cheaper answer. `default-features` here is therefore byte-identical
to upstream, and the whole `qtbase` delta is two added feature definitions.

What actually collapses `tests/vcpkg.json` to a single `qtbase` entry is naming the
backends as **platform-qualified Feature Objects** — `platform` works on an
individual feature, not just on the dependency as a whole:

```json
{
  "name": "qtbase",
  "default-features": false,
  "features": [
    "async-io", "concurrent", "dnslookup", "network", "pcre2",
    { "name": "ioring",          "platform": "linux | windows" },
    { "name": "openssl",         "platform": "linux" },
    { "name": "schannel",        "platform": "windows" },
    { "name": "securetransport", "platform": "osx" }
  ]
}
```

One entry, three platforms, no port-side defaults needed.

### Why `openssl-runtime` and not plain `openssl` on Linux

`openssl-runtime` is orthogonal to the three backends above: it does not choose a
different backend, it changes how the OpenSSL one is *bound*. Setting
`INPUT_openssl=runtime` makes Qt resolve libssl/libcrypto through `QLibrary` at run
time instead of linking them, and it is what `ci/build_qt6.sh` passes.

For a redistributable SDK the difference is not cosmetic. Measured on `arm64-linux`:

| | `openssl` alone (linked) | with `openssl-runtime` |
| --- | --- | --- |
| TLS plugin | links `libssl.so.3`, `libcrypto.so.3` | links neither |
| `libQt6Network.so` | `DT_NEEDED: libcrypto.so.3` | nothing |
| Target has no OpenSSL, or a different soname | the library **fails to load** | loads; TLS unavailable |
| Distro portability | bound to one soname | Qt tries several at run time |

That last row is the reason to prefer it: the SDK keeps working across targets with
different OpenSSL versions, degrading to "no TLS" instead of refusing to load. The
`openssl` feature stays selected alongside it — Qt still needs the headers to
compile the backend, and `openssl-runtime` depends on it for that reason.

`verify.sh` reads which mode the manifest selected and asserts accordingly, so it
stays a real check either way: under `runtime` it requires the plugin to link
neither library, to import `QLibrary`, and no Qt library to be bound to an OpenSSL
soname; under `linked` it requires the opposite.

## Triplets

`triplets/` holds the six overlay triplets, four of them moved here from
`rankone-ffmpeg-jetson/ci/vcpkg/` so the port-specific workarounds in them can be
retired as the ports absorb them. **Registries serve ports only** — vcpkg has no
mechanism to distribute triplets — so a consumer still points
`overlay-triplets` at a local checkout of this repository (a submodule is the
tidy way).

Retired, because the ports now cover them:

- `-DWITH_CAROTENE=OFF` (arm64-linux, arm64-osx) — `carotene` is a feature here,
  and any `"default-features": false` selection already leaves it off. The
  original comment already said "fixed in 4.10.0#2".
- `-DWITH_MSMF=OFF` (x64-windows) — likewise, `msmf` is a feature.

Added, because they are parity items that a port *cannot* express — visibility is
a compiler flag, and `WITH_PTHREADS_PF` has no upstream feature:

- `-fvisibility=hidden` for opencv on the three non-Windows triplets
- `-DWITH_PTHREADS_PF=OFF` for opencv everywhere

### Linkage

Static by default. Dynamic for the LGPL set — `qtbase`, `ffmpeg`, `openssl`,
`numactl` — **on every triplet except `arm64-ios`**, with the same anchored match
in each:

```cmake
set(VCPKG_LIBRARY_LINKAGE static)
if(PORT MATCHES "^(qtbase|ffmpeg|openssl|numactl)$")
    set(VCPKG_LIBRARY_LINKAGE dynamic)
endif()
```

The LGPL's relinking requirement is met by shipping those as replaceable shared
libraries; static linking would push that obligation onto whoever redistributes
the SDK. Everything else — `opencv4`, `libuv`, `amqpcpp`, `prometheus-cpp` and the
rest — stays static and links straight in. `numactl` is Linux-only and simply never
matches elsewhere; the list is identical in every triplet on purpose, so there is
one rule to reason about rather than four.

Measured on `arm64-linux`: `libQt6Core.so`, `libavcodec.so`, `libssl.so`,
`libcrypto.so` shared with no static counterpart; `libopencv_core4.a`, `libuv.a`,
`libamqpcpp.a` static with no shared counterpart.

**`arm64-ios` is the deliberate exception: everything static, LGPL set included.**
iOS has no practical way to ship and load third-party shared libraries, so the
relinking path the LGPL expects is forfeited and that obligation moves to whoever
ships the app. The ROC SDK already works this way on iOS — it is a platform
constraint rather than a preference — but it is a legal exposure and not merely a
build setting, so it is stated in `triplets/arm64-ios.cmake` too rather than left
implicit. Android keeps the rule: an APK ships `.so` files in `lib/<abi>/`, so
dynamic is both achievable and honest there.

### Frameworks

Enabled on **macOS only**, through qtbase's `framework` feature. That feature is
declared `supports: "osx & !static"`, so it needs the dynamic linkage `arm64-osx`
gives qtbase — and it is unavailable on iOS twice over: iOS is not `osx`, and that
triplet is static. Frameworks and static linking are mutually exclusive here; iOS
gets static archives, and bundling those into a `.framework` is an SDK packaging
step rather than something vcpkg does. `verify.sh` asserts `Qt6Core.framework` on
macOS and skips the check with an explanation on iOS.

`VCPKG_FIXUP_ELF_RPATH` is set on the two Linux triplets, carried over from the
original. Worth knowing: it only *rewrites* existing `RPATH`/`RUNPATH` entries to
be `$ORIGIN`-relative, and the artifacts here come out with no `RUNPATH` at all —
so the consuming link step still has to set one. That is the job `build_qt6.sh`'s
`-R /LONG/ENOUGH/TO/REPLACE` placeholder was for.

## Parity with ci/build_qt6.sh and ci/build_opencv.sh

These ports exist to reproduce, through vcpkg, what
`rankone-ffmpeg-jetson/ci/build_qt6.sh` and `ci/build_opencv.sh` configure by
hand. What follows is the full accounting, including what does *not* match.

### Qt

| `build_qt6.sh` | Here |
| -------------- | ---- |
| `-no-gui -no-widgets -no-opengl -no-dbus -no-harfbuzz -no-freetype -no-icu -no-sql-sqlite -no-feature-sql -no-feature-testlib` | `"default-features": false`, on every edge |
| `-ssl` | `openssl` feature — linked, which is what is used here |
| `-openssl-runtime` | the **`openssl-runtime`** feature, selected on Linux |
| `-securetransport` (macOS) | `securetransport` feature |
| `-schannel` (Windows) | the **`schannel`** feature, new here |
| `-release`, `-shared`, `-no-framework` | triplet: `VCPKG_BUILD_TYPE release`, `VCPKG_LIBRARY_LINKAGE dynamic` for `qtbase` |
| `-R /LONG/ENOUGH/TO/REPLACE` | triplet: `VCPKG_FIXUP_ELF_RPATH ON` |
| `-nomake examples -nomake tests` | the port already does this |
| `-qt-pcre`, `-qt-zlib` | the `pcre2` feature and the `zlib` dependency — vcpkg's builds rather than Qt's bundled copies |
| `-no-feature-xml` | **not available.** The port forces `FEATURE_xml=ON` because moc needs it |

### OpenCV

| `build_opencv.sh` | Here |
| ----------------- | ---- |
| `BUILD_opencv_{calib3d,gapi}=OFF` | `calib3d` and `gapi` were already features; `"default-features": false` leaves them off |
| `BUILD_opencv_{flann,objdetect,photo,stitching,video}=OFF` | **new features**, so `"default-features": false` leaves them off |
| `BUILD_opencv_features2d=ON` | **new feature** — must be listed explicitly |
| default `CV_ENABLE_INTRINSICS`, filesystem and thread support | the `intrinsics`, `fs` and `thread` features — must be listed explicitly |
| `WITH_CAROTENE=OFF` | `carotene` was already a feature; `"default-features": false` leaves it off |
| `WITH_{1394,ADE,EIGEN,FFMPEG,GSTREAMER,GTK,IPP,MSMF,OPENCL,QUIRC,V4L,VTK}=OFF` | features, all off under `"default-features": false` |
| `WITH_{ITT,JASPER,LAPACK,OBSENSOR,OPENCLAMDBLAS,OPENCLAMDFFT,VA,VA_INTEL}=OFF`, `BUILD_{DOCS,EXAMPLES,PACKAGE,PERF_TESTS,TESTS,IPP_IW,ITT}=OFF`, `BUILD_opencv_{apps,java,js,python3}=OFF` | the port already does all of this |
| `BUILD_opencv_ts=OFF` | implied by the port's `BUILD_TESTS=OFF` |
| `BUILD_SHARED_LIBS=OFF` | triplet: `VCPKG_LIBRARY_LINKAGE static` |
| `BUILD_{JPEG,PNG,TIFF,WEBP,OPENEXR,OPENJPEG,PROTOBUF}=ON` | the vcpkg ports instead of OpenCV's bundled copies |
| `-DCMAKE_CXX_FLAGS=-fvisibility=hidden` | triplet, on the three non-Windows triplets |
| `WITH_PTHREADS_PF=OFF` | triplet, everywhere |
| `WITH_AVFOUNDATION=OFF` | **not exposed by the port**; force it from a triplet's `ADDITIONAL_BUILD_FLAGS` if it matters |

The six new features are `features2d`, `flann`, `objdetect`, `photo`,
`stitching` and `video`. All six are in `default-features`, so upstream
behaviour is unchanged; they only become useful to someone who has already said
`"default-features": false`.

Their inter-module dependencies are declared from OpenCV 4.12.0's own
`ocv_define_module` calls — `calib3d` requires `features2d` and `flann`,
`objdetect` requires `calib3d`, `stitching` requires `calib3d` + `features2d` +
`flann`. That matters because OpenCV's CMake silently *drops* a module whose
required dependencies are missing. Declaring them means vcpkg rejects an
impossible selection instead of quietly building less than you asked for.

`intrinsics`, `fs` and `thread` are not new — they are upstream defaults that
`"default-features": false` silently removes. `intrinsics` is the one that hurts:
it maps to `CV_ENABLE_INTRINSICS`, so dropping it costs every SSE/AVX and NEON
code path in OpenCV, with no error and no obvious symptom beyond being slow.

### Remaining gaps

- **`-no-feature-xml` (Qt).** The port hard-enables `FEATURE_xml` because moc is
  built from it. Reaching parity would mean disabling xml for the target while
  keeping it for the host build; not attempted.
- **`WITH_FLATBUFFERS`.** The port ties this to `dnn`, so it is on wherever
  `dnn` is; `build_opencv.sh` has it off. A superset — it adds TFLite import.
- **Versions differ.** These ports are OpenCV 4.12.0 and Qt 6.11.1, from the
  pinned baseline; the scripts build 4.8.1 and 6.8.2.

## Consuming this registry

**[`tests/vcpkg.json`](tests/vcpkg.json) is the complete, working answer** — copy it
over `ci/vcpkg.json` and adjust. It is what CI builds, so it is proven rather than
illustrative.

Everything lives in that one file, so there is no `vcpkg-configuration.json`.
`builtin-baseline` pins the upstream catalogue as usual, and the embedded
`vcpkg-configuration` object adds this registry on top of it:

```json
"builtin-baseline": "3c5d90a305ff00ca841f085a74a7ce74ee777dee",
"vcpkg-configuration": {
  "registries": [
    {
      "kind": "git",
      "repository": "https://github.com/KOConchobhair/vcpkg-registry",
      "baseline": "<commit sha of this repo>",
      "packages": [ "ffmpeg", "jetson-multimedia-api", "jetson-nvmpi", "opencv4", "qtbase" ]
    }
  ],
  "overlay-triplets": [ "../triplets" ]
}
```

Three things worth knowing about that block:

- **The fallback is implicit.** Omitting `default-registry` makes vcpkg use the
  builtin registry at `builtin-baseline`, which is exactly the conventional
  shorthand for it. Spelling out a `"kind": "git"` `default-registry` pointing at
  microsoft/vcpkg is equivalent, and mutually exclusive with `builtin-baseline` —
  worth knowing about if you ever want to resolve against an internal mirror.
- **`packages` is what activates this registry.** Ports listed there resolve here
  and shadow upstream; everything else falls back to the builtin registry. It also
  means anything in `overrides` for those ports must name a version *this*
  registry has.
- **`overlay-triplets` has to be a path.** Registries distribute ports only —
  there is no mechanism for shipping triplets — so add this repository as a git
  submodule and point at its `triplets/` directory. Relative paths resolve against
  the manifest's own directory.

Resolution is visible in the output, which is the easiest way to show which
registry served what — anything annotated `git+` came from here, everything else
from the builtin registry at the pinned baseline. `tests/vcpkg.json` deliberately
depends on `amqpcpp` and `libuv` for exactly this reason: neither is in the
`packages` list, so both have to come from upstream.

```
ffmpeg[...]:arm64-linux@7.0.2#8   -- git+/registry@111c5649...
opencv4[...]:arm64-linux@4.12.0#8 -- git+/registry@8695c0ae...
qtbase[...]:arm64-linux@6.11.1#2  -- git+/registry@298d2167...
amqpcpp:arm64-linux@4.3.27
libuv:arm64-linux@1.52.1
openssl:arm64-linux@3.6.3
protobuf:arm64-linux@3.19.4
```

### Changes ci/vcpkg.json needs

Line-by-line against the file as it stands today. Items 1–5 are **required** —
without them the build either fails to resolve or silently produces something
other than what `ci/build_qt6.sh` and `ci/build_opencv.sh` produce.

| # | Change | Why |
| - | ------ | --- |
| 1 | **Add a `registries` array to the existing `vcpkg-configuration` block**, with this registry and `packages`: `ffmpeg`, `jetson-multimedia-api`, `jetson-nvmpi`, `opencv4`, `qtbase`. Keep `builtin-baseline` as it is. | Nothing here is used otherwise. That block already holds `overlay-triplets`, so this extends it rather than adding it. |
| 2 | **Delete the `opencv4` override** (`4.8.0#22`) | This registry serves 4.12.0#8. An override naming a version the authoritative registry does not have fails to resolve. |
| 3 | **Delete the `ffmpeg` override** (`7.0.2#7`) | Required, not merely redundant: this registry serves `7.0.2#8`, so an override naming `#7` no longer resolves. It was renumbered precisely so a modified port stops claiming upstream's identifier. |
| 4 | **Add `features2d`, `intrinsics`, `fs`, `thread` to the `opencv4` features** | The four silent ones. `features2d` is newly a feature; the other three are upstream defaults that the existing `"default-features": false` was already discarding. `intrinsics` is the expensive one — it maps to `CV_ENABLE_INTRINSICS`, so without it OpenCV has no SSE/AVX or NEON code paths at all. |
| 5 | **Add `"default-features": false` to the `qtbase` edge inside the `gui` feature** | The most consequential line in this list. Without it, enabling `gui` discards the headless configuration entirely and unions in `icu`, `libpq`, `testlib`, `freetype`, `harfbuzz` and the X11 stack. Measured under "`default-features: false` has to be on *every* edge". |
| 6 | **Collapse the two `qtbase` entries into one**, with the TLS and async-io backends as platform-qualified Feature Objects | Today there are `osx` and `!osx` entries, so Windows takes the `!osx` branch and links OpenSSL even though **`schannel`**, new in this registry's port, gives it a native stack. One entry covers all three platforms — see "TLS backends" for the exact block. |
| 7 | **Point `overlay-triplets` at this repository's `triplets/`** and delete `ci/vcpkg/` | Optional; see "Triplets". Retires the `WITH_CAROTENE`/`WITH_MSMF` hacks and adds `-fvisibility=hidden`. |
| 8 | **Keep the `protobuf` override** (`3.19.4`) | Kept deliberately — `tests/vcpkg.json` carries it, so CI tests it. Note the risk: `opencv4` 4.12.0's `dnn` is patched against a far newer protobuf, and the builds here that passed used the baseline's 6.33.4. Whether 4.12.0 compiles against 3.19.4 is unproven and is precisely what the pipeline will answer. |

`tests/vcpkg.json` has all eight applied, plus a `jetson` feature for
`ffmpeg[nvmpi]` that the current manifest has no equivalent of. Its `$comment`
fields carry the reasoning inline, since a manifest cannot hold real comments.

## Adding or updating a port

Commit the port, then record its version:

```
vcpkg x-add-version <port> \
  --x-builtin-ports-root=./ports \
  --x-builtin-registry-versions-dir=./versions \
  --skip-version-format-check
```

`versions/<prefix>-/<port>.json` maps each version to the git tree of its port
directory, so the port must be committed before its version is recorded.

### Version numbering

A vendored port is **upstream's `port-version` plus one**, and each has exactly one
entry — nothing here has been published, so there is no reason to carry a trail of
intermediate revisions:

| Port | Upstream | Here |
| ---- | -------- | ---- |
| `qtbase` | 6.11.1#1 | 6.11.1#2 |
| `opencv4` | 4.12.0#7 | 4.12.0#8 |
| `ffmpeg` | 7.0.2#7 | 7.0.2#8 |
| `jetson-multimedia-api` | — | 36.4.0#0 |
| `jetson-nvmpi` | — | 3.10.0#0 |

Two reasons for +1 rather than restarting at 0. It keeps provenance legible — #8
reads as "upstream's #7 plus our delta" — and, more importantly, it stops a
modified port from claiming a version identifier that upstream already uses for
different content. `ffmpeg` used to sit at 7.0.2#7, the same as upstream's
unmodified port, which is exactly the ambiguity to avoid.

`--skip-version-format-check` is needed because of this: vcpkg sees a version new
to *this* registry and wants `#0`. The provenance is worth more than the check.

**After the first push this all freezes.** Upstream's guidance is not to change a
published version's `git-tree`, because that would change what an already-resolved
dependency means. Renumbering was free only because nothing had been pushed; from
then on, a change to a port means a new `port-version`.

## Testing

`.github/workflows/ports.yml` is the gate: on every push and pull request it builds
`tests/vcpkg.json` on a native runner for **every triplet this registry ships**, and
runs `tests/verify.sh` on the result. All runner images used are free for public
repositories:

| Triplet | Runner | Host triplet |
| ------- | ------ | ------------ |
| `x64-linux` | `ubuntu-22.04` | — |
| `arm64-linux` | `ubuntu-22.04-arm` | — |
| `arm64-osx` | `macos-14` | — |
| `x64-windows` | `windows-2022` | — |
| `arm64-android` | `ubuntu-22.04` | `x64-linux` |
| `arm64-ios` | `macos-14` | `arm64-osx` |

The last two are cross builds, so the host triplet is the machine doing the
building — Android and iOS binaries cannot run on the runner, and vcpkg needs host
tools (moc, and the host qtbase behind it) it can actually execute.

`fail-fast: false`, so one platform breaking still tells you about the others.
`tests/run.sh` is the single implementation on all six — the workflow runs it under
Git Bash on Windows and converts the Actions-supplied paths with `cygpath`.
`tests/verify.sh` adapts its file naming and inspection tooling per platform, and
its central check becomes *"did this platform produce its own TLS backend and not
somebody else's"* — `qopensslbackend` on Linux, `qsecuretransportbackend` on macOS,
`qschannelbackend` on Windows. It runs in `consumer` mode, so it resolves through
`versions/` and the manifest's own registry reference rather than overlay ports:
the exact path a consumer takes. Every mode here is vcpkg **manifest mode**; there
is no classic-mode path.

Locally, `tests/build.sh` does the same thing in Ubuntu 22.04 containers under
colima:

```
./tests/build.sh arm64            # build tests/vcpkg.json through the registry, then verify
./tests/build.sh arm64 resolve    # resolution only, after any vcpkg.json edit
./tests/build.sh arm64 overlay    # dev loop: working tree via --overlay-ports
```

Use it for arm64 and for iteration. **Build x64 in CI, not on an Apple-silicon
workstation** — x64 there runs under Rosetta, which intermittently leaves cmake
waiting forever on a child that already exited. Nothing in the ports causes it;
a native x86_64 runner is clean. See `tests/README.md`.

## FFmpeg with hardware acceleration

The goal is one LGPL FFmpeg per architecture:

- **x64** — CUDA: `nvcodec` (nvenc/nvdec/cuvid) plus `cuda-llvm` (CUDA filters)
- **arm64** — the same, plus `nvmpi` for Jetson

```json
{
  "dependencies": [
    { "name": "ffmpeg", "features": ["nvcodec", "cuda-llvm"] },
    { "name": "ffmpeg", "features": ["nvmpi"], "platform": "linux & arm64" }
  ]
}
```

### `cuda-llvm`, not `cuda-nvcc`

Both satisfy `scale_cuda_filter_deps_any`, but `cuda_nvcc` is on FFmpeg's
`HWACCEL_LIBRARY_NONFREE_LIST`, so it forces `--enable-nonfree` and produces a binary that
**cannot be redistributed**. That is exactly why NVIDIA's own Jetson FFmpeg packages are built
`--enable-nonfree`. `cuda-llvm` compiles the same kernels with clang and stays redistributable.

**Build host prerequisite:** clang. vcpkg supplies neither clang nor nvcc.

### `nvmpi` is JetPack 6 only

Orin's video engines are reachable only through the V4L2 multimedia API, because NVIDIA does not
publish `libnvidia-encode`/`libnvidia-decode` for JetPack 6. JetPack 7 (Thor) does publish them,
so `nvcodec` covers Thor directly. One FFmpeg built with both features spans Orin and Thor.

`jetson-nvmpi` links stub libraries, so it builds with no Jetson attached; on the device the real
Tegra libraries satisfy the same sonames. `libavcodec` resolves `libnvmpi` through `dlopen`, so
consumers must ship `libnvmpi.so` even though nothing links it.

### Filesystem requirement

vcpkg's buildtrees must be on a **case-sensitive** filesystem. The Multimedia API ships
`nvbufsurface.h` and `NvBufSurface.h` side by side; on a case-insensitive filesystem they collapse
into one file and the build fails with `'NvBufSurf' has not been declared`. This bites when
`VCPKG_ROOT` points at a macOS volume or a bind mount from one. The ports fail early with a clear
message rather than at compile time. `tests/build.sh` keeps buildtrees in a docker volume on the
VM's ext4 for this reason.

## Verified

### qtbase and opencv4

**`arm64-linux` — built and verified.** `tests/vcpkg.json` installs completely — 70
packages including `ffmpeg`, `ffprobe`, `amqpcpp` and `libuv` — and
`tests/verify.sh` passes every check with nothing skipped:

- `opencv4 4.12.0#8` has `core`, `imgproc`, `imgcodecs`, `dnn`, `features2d`, and
  none of `calib3d`, `flann`, `objdetect`, `photo`, `stitching`, `video`, `gapi`,
  `highgui`, `ts`
- all 2616 defined globals in `libopencv_core4.a` are `HIDDEN`, none `DEFAULT` —
  the triplet's `-fvisibility=hidden` reached the compiler
- `qtbase 6.11.1#2` has `Core`, `Network`, `Concurrent` and none of `Gui`,
  `Widgets`, `Sql`, `Test`, `DBus`, `OpenGL`
- the TLS backend is `qopensslbackend` and no other platform's backend leaked in;
  it links neither `libssl` nor `libcrypto` and imports `QLibrary`, and no Qt
  library is bound to an OpenSSL soname — `openssl-runtime` took effect, matching
  `ci/build_qt6.sh`. `verify.sh` reads the mode out of `tests/vcpkg.json`, so it
  asserts the opposite if plain linked `openssl` is selected instead
- no Qt library links ICU
- linkage split as intended: `libQt6Core.so`, `libavcodec.so`, `libssl.so`,
  `libcrypto.so` shared with no static counterpart; `libopencv_core4.a`, `libuv.a`,
  `libamqpcpp.a` static with no shared counterpart

Also measured, by resolution rather than by build: enabling the manifest's `gui`
feature with `"default-features": false` on its edge adds `gui`, `sql`,
`sql-sqlite`, `widgets` and nothing else; without it, the entire default set
arrives instead.

**`x64-linux`, `arm64-osx`, `x64-windows` — written, not yet run.** Nothing here
can build them: x64 on an Apple-silicon workstation goes through Rosetta, which
intermittently leaves cmake waiting on a child that already exited, and macOS and
Windows have no local runner at all. `.github/workflows/ports.yml` covers all three
on native images. That workflow has had no run yet, since nothing has been pushed;
expect first-run fixups on the macOS and Windows legs in particular.

The `versions/` database was verified independently of any build: each port's
recorded version matches its `vcpkg.json`, `versions/baseline.json` agrees with all
five, every recorded `git-tree` resolves to a real tree object on `trunk`, and the
commit the manifest names as its baseline carries the complete database.

### ffmpeg

`arm64-linux` against vcpkg at the consuming project's baseline, with
`ffmpeg[core,avcodec,avformat,avfilter,swscale,swresample,nvcodec,cuda-llvm,nvmpi,ffmpeg]`:

- 7 `*_nvmpi` codecs in `libavcodec`
- `scale_cuda`, `overlay_cuda`, `thumbnail_cuda`, `bwdif_cuda`, `yadif_cuda` in `libavfilter`
- `ffmpeg -hwaccels` reports both `cuda` and `nvmpi`
- stub libraries kept out of `lib/`

Not yet built: `x64-linux` FFmpeg (`nvcodec` + `cuda-llvm`), and no test has run on Jetson
hardware.
