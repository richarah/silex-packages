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

- **build.yml** — triggers on push to `aports/**` or `packages.list`.
  Builds all packages for both architectures, signs the index, commits back to main.
- **build-single.yml** — `workflow_dispatch` with `package` and `arch` inputs.
  Rebuilds one package without touching the rest.

Both run inside `ghcr.io/richarah/silex:slim` (dog-fooding).

---

## Version pinning

| Image | Strategy |
|-------|---------|
| `silex:slim` | latest upstream stable |
| `silex:compat-ubuntu-24.04` | exact Ubuntu 24.04 versions |
| `silex:compat-debian-12` | exact Debian bookworm versions |

Compat builds use the same APKBUILDs with different version pins.
Track them in separate branches or subdirectories.
