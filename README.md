# silex-packages

Custom Alpine `.apk` package repository for [Silex](https://github.com/richarah/silex)
base images. Every package is rebuilt from upstream source with:

- **Compiler**: clang
- **Flags**: `-O3 -march=x86-64-v3 -flto=thin -fomit-frame-pointer`
- **Linker**: mold, `-flto=thin`
- **Strip**: `strip --strip-unneeded` on all binaries and `.so` files
- **Compression**: `pigz -9`

Architectures: `x86_64`, `aarch64`.

Repository URL: `https://richarah.github.io/silex-packages/`

---

## Using this repository

In a Silex container, `/etc/apk/repositories` already includes this repo:

```
https://richarah.github.io/silex-packages/x86_64/
https://packages.wolfi.dev/os
```

The public key is pre-installed in `/etc/apk/keys/`. Run `apk update` to sync.

To use from a non-Silex Alpine container, add the repo and key manually:

```sh
wget -O /etc/apk/keys/silex-packages.rsa.pub \
    https://richarah.github.io/silex-packages/keys/silex-packages.rsa.pub
echo "https://richarah.github.io/silex-packages/x86_64/" \
    >> /etc/apk/repositories
apk update
```

---

## Package list

See `packages.list` for the full list with upstream URLs and version pins.

Packages are split into three build tiers:

- **Tier 1** — built immediately, most common in Dockerfiles (libssl, zlib, libcurl, libpq, etc.)
- **Tier 2** — next: graphics, boost, protobuf, gRPC, extra network libs
- **Tier 3** — on request: audio, geo, niche

---

## Adding a package

1. Create `aports/<pkgname>/APKBUILD` following the template below.
2. Add an entry to `packages.list`.
3. Run `scripts/gen-checksums.sh <pkgname>` to populate `sha512sums`.
4. Commit and push. CI picks it up automatically.

### APKBUILD template

```sh
# Maintainer: silex-ci <ci@silex>
pkgname=example
pkgver=1.0.0
pkgrel=0
pkgdesc="Short description"
url="https://example.com"
arch="x86_64 aarch64"
license="MIT"
makedepends=""
subpackages="$pkgname-dev"
source="https://example.com/example-$pkgver.tar.gz"
sha512sums="SKIP"

build() {
    cd "$builddir"
    ./configure --prefix=/usr
    make -j$JOBS
}

package() {
    cd "$builddir"
    make install DESTDIR="$pkgdir"
}
```

Rules:
- `pkgrel=0` on initial build; increment for rebuilds of the same upstream version.
- Always set `arch="x86_64 aarch64"`.
- Always use `$JOBS` for parallel make.
- Use cmake `-G Ninja` or meson where upstream supports it.
- Don't patch unless necessary. Document every patch.
- `options="!check"` if tests require network or are flaky in containers.
- Pass `CC`, `CXX`, `CFLAGS`, `CXXFLAGS`, `LDFLAGS` explicitly to autotools.
  cmake and meson pick them up from the environment automatically.

**provides= rules**
- `provides=` must not include the package's own name. abuild's validate_provides()
  rejects it. List only virtual/compat names that other packages depend on.

**subpackages= rules**
- Do not add `$pkgname-static` to `subpackages=`. `default_dev()` moves all `.a` files
  to the `-dev` subpackage, leaving nothing for `default_static()` to claim. The build
  will fail with `cd: can't cd to $subpkgdir`. Static libs are available from `-dev`.

**cmake packages**
- Always `cd "$builddir"` at the top of both `build()` and `package()`. Each abuild
  function runs in `$srcdir`, not `$builddir`.
- Always pass `-DCMAKE_INSTALL_LIBDIR=lib`. On x86_64, cmake defaults to `lib64`; abuild
  rejects files under `/usr/lib64`.
- If CMakeLists.txt is not at the tarball root, pass `-S <subdir>` explicitly.
  Example: zstd's CMakeLists.txt is at `build/cmake/`, not the root.

**LTO + two-step make (bzip2 pattern)**
- Some packages compile object files then re-link them in a second make invocation.
  With `-flto=thin`, the object files are LLVM bitcode and the re-link fails with
  `file format not recognized`. Strip LTO flags for the first pass:
  ```sh
  _cflags_nolto=$(printf '%s' "$CFLAGS" | sed 's/-flto[^ ]*//g')
  make -f Makefile-libbz2_so CC="$CC" CFLAGS="$_cflags_nolto -fPIC"
  make CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" -j$JOBS
  ```

**Source URL reliability**
- Prefer GitHub Releases URLs: `https://github.com/<org>/<repo>/releases/download/...`
  They do not move when new versions are released.
- gmplib.org is unreliable (frequent timeouts). Use the GNU mirror:
  `https://ftp.gnu.org/gnu/gmp/gmp-$pkgver.tar.xz`

---

## Repository structure

```
silex-packages/
  x86_64/
    APKINDEX.tar.gz
    *.apk
  aarch64/
    APKINDEX.tar.gz
    *.apk
  aports/
    <pkgname>/APKBUILD
    ...
  keys/
    silex-packages.rsa.pub
  scripts/
    build-all.sh      # build every package in dep order
    build-one.sh      # build a single package
    index.sh          # generate + sign APKINDEX
    list-packages.sh  # list all package names
    gen-checksums.sh  # populate sha512sums in APKBUILDs
  abuild.conf         # shared compiler flags
  packages.list       # name, version, URL, sha512
```

---

## Signing

Keys are managed as GitHub Actions secrets:

| Secret | Content |
|--------|---------|
| `SILEX_PKG_RSA` | RSA private key (PEM) |
| `SILEX_PKG_RSA_PUB` | RSA public key (PEM) |

To generate a new pair:

```sh
abuild-keygen -a -n
# private key: ~/.abuild/silex-packages.rsa
# public key:  /etc/apk/keys/silex-packages.rsa.pub
```

The public key is committed to `keys/` and shipped inside Silex images.

---

## CI

Two workflows:

- **build.yml** — triggers on push to `aports/**`, `packages.list`, or `scripts/ci-build.sh`.
  Builds all packages for both architectures, signs the index, commits back to main.
- **build-single.yml** — `workflow_dispatch` with `package` and `arch` inputs.
  Rebuilds one package without touching the rest.

Both run inside `cgr.dev/chainguard/wolfi-base:latest`. `scripts/ci-build.sh` builds
abuild 3.15.0 from Alpine source (abuild is not in the Wolfi repo) and applies three
patches before starting the build:

1. `abuild-sign`: `sigtype=RSA` → `sigtype=RSA256` (SHA-256 signatures, required by Wolfi apk).
2. `abuild`: `die "Failed to create index"` → `true` (Wolfi apk returns EKEYREJECTED on
   intermediate index steps; our pipeline handles final indexing separately).
3. `abuild` postcheck: uncompressed man pages auto-gzip instead of setting `e=1` (packages
   that install uncompressed man pages are fixed in-place rather than rejected).

---

## Version pinning

| Image | Strategy |
|-------|---------|
| `silex:slim` | latest upstream stable |
| `silex:compat-ubuntu-24.04` | exact Ubuntu 24.04 versions |
| `silex:compat-debian-12` | exact Debian bookworm versions |

Compat builds use the same APKBUILDs with different version pins.
Track them in separate branches or subdirectories.
