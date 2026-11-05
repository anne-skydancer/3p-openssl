# 3p-openssl (Vulkanstorm)

[Autobuild][]-packaged [OpenSSL][] 3.5 LTS for the Vulkanstorm viewer, forked
from secondlife/3p-openssl (1.1.1w). Prototype: built and tested locally on
windows64; not published. See the viewer's `doc/tls-upgrade-patches.md`.

## What changes against LL's package

- OpenSSL 3.5.9 (LTS, supported until 2030-04-08), Apache-2.0.
- Source: the release tarball, not a git submodule. `build-cmd.sh` pins its
  SHA-256 (`603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`)
  and refuses any other file. The tarball's detached signature
  (`openssl-3.5.9.tar.gz.asc`) verifies against `pubkeys.asc` from
  openssl-library.org (subkey `C46E D3F2 CBEF DA1F DAAD A442 64ED 7B1D CCE7 1CB2`).
- `Configure` adds `no-module`: the legacy provider is compiled into
  `libcrypto` (`-DSTATIC_LEGACY`), so the viewer can load it by name for RC4
  (its `bin_conf.dat` credential store) with no `legacy.dll`/`legacy.so` to
  stage. Everything else is LL's: `zlib no-zlib-dynamic threads no-shared`,
  zlib from the zlib-ng package, static `libssl`/`libcrypto`.
- Windows: `/MD` (from `LL_BUILD_RELEASE`) is required; with OpenSSL's
  default `/MT` the `openssl.exe` link fails against the `/MD` zlib-ng
  package. OpenSSL's own `/nologo /W3 /wd4090` are kept in front of
  `LL_BUILD_RELEASE`, which replaces them otherwise.
- Smoke test after the build: `openssl list -providers` must show the legacy
  provider as built in and active, and RC4 through it must give the known
  answer (`9fe92c92268c6ab869a9fa` for key `00..0f`, `vulkanstorm`).
- The OpenSSL test suite runs unless `DISABLE_UNIT_TESTS=1`
  (`HARNESS_JOBS` = CPU count).

## Build

Windows needs Strawberry Perl (`C:\Strawberry\perl\bin`) and NASM on `PATH`
(or in `%LOCALAPPDATA%\bin\NASM`); `jom` is used when present, else `nmake`.
`AUTOBUILD_VARIABLES_FILE` must point at the build variables
(FirestormViewer/fs-build-variables, as the viewer's CI uses).

```
autobuild install -A 64
autobuild build -A 64
autobuild package -A 64 --archive-format tzst
```

Set `OPENSSL_TARBALL=<path>` to use an already downloaded tarball (it is
still checked against the pinned SHA-256).

## Releasing (not done)

1. Bump `VERSION.txt` (`<OpenSSL version>.<package revision>`).
2. Tag `v<VERSION>`; the workflow builds windows64 and linux64 and publishes
   the archives with their SHA-256.
3. Put the release URLs and SHA-256 hashes in the viewer's and 3p-curl's
   `autobuild.xml`.

[Autobuild]: https://wiki.secondlife.com/wiki/Autobuild
[OpenSSL]: https://openssl-library.org/
