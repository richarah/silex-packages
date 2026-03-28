# silex-packages

Custom Alpine `.apk` package repository for [Silex](https://github.com/richarah/silex)
base images. Packages are recompiled from Debian bookworm sources with:

- **Compiler**: clang
- **Flags**: `-O3 -march=x86-64-v3 -flto=thin -fomit-frame-pointer`
- **Linker**: mold, `-flto=thin`
- **Strip**: `strip --strip-unneeded` on all ELF binaries and `.so` files

Packages that do not contain versioned shared libraries (`.so.N`) are repacked
directly from the Debian binary `.deb` without recompilation.

Architectures: `x86_64`, `aarch64`.

Repository URL: `https://richarah.github.io/silex-packages/`

---

## Using this repository

In a Silex container, `/etc/apk/repositories` already includes this repo and
the public key is pre-installed in `/etc/apk/keys/`. Run `apk update` to sync.

To use from a non-Silex Alpine or Wolfi container:

```sh
wget -O /etc/apk/keys/silex-packages.rsa.pub \
    https://richarah.github.io/silex-packages/keys/silex-packages.rsa.pub
echo "https://richarah.github.io/silex-packages/x86_64/" \
    >> /etc/apk/repositories
apk update
```

Replace `x86_64` with `aarch64` as appropriate.

---

## How it works

The pipeline runs inside a `debian:bookworm` container using only standard
Debian tools (`apt-get`, `dpkg-source`, `dpkg-deb`, `clang`, `mold`, etc.).
No abuild, no Alpine toolchain, no APKBUILDs.

1. **resolve-deps.sh** — computes the transitive dependency closure of
   `config/seeds.list` using `apt-cache depends --recurse`. Packages in
   `config/skip.list` are excluded.

2. **classify.sh** — for each package in the closure, downloads the `.deb`
   and inspects its file list. Packages containing versioned `.so.N` files
   (real shared libraries) are classified as `recompile`; everything else as
   `repack`. Override lists in `config/` take priority.

3. **repack.sh** — downloads the Debian binary `.deb`, extracts the file tree
   with `dpkg-deb -x`, converts the Debian control metadata to `.PKGINFO`
   format via `mkpkginfo.sh`, and assembles an unsigned `.apk` with `mkapk.sh`.

4. **recompile.sh** — fetches the Debian source package, unpacks it with
   `dpkg-source`, auto-detects the build system (autoconf / cmake / meson /
   dpkg-buildpackage), builds with Silex CFLAGS, installs to a staging
   directory, strips binaries, generates `.PKGINFO` from `apt-cache show`, and
   assembles an unsigned `.apk`.

5. **index.sh** — runs `apk index --allow-untrusted` on all `.apk` files to
   generate `APKINDEX.tar.gz`, then signs the index with `sign.sh`.

Individual `.apk` files are **unsigned**. Security is provided by the signed
`APKINDEX.tar.gz`: apk verifies each downloaded package's checksum against
the trusted index.

---

## Adding a package

To add a package to the repository:

1. Add its Debian package name to `config/seeds.list`.
2. If `classify.sh` would misclassify it, add it to
   `config/recompile-override.list` or `config/repack-override.list`.
3. Push. CI rebuilds the full closure automatically.

To exclude a package from the closure (e.g. it is already in the base image):

1. Add its name to `config/skip.list`.

Classification overrides:

- `config/recompile-override.list` — force recompile even if no versioned `.so`
- `config/repack-override.list` — force repack even if versioned `.so` present

---

## Repository structure

```
silex-packages/
  x86_64/
    APKINDEX.tar.gz        signed index
    *.apk                  unsigned packages
  aarch64/
    APKINDEX.tar.gz
    *.apk
  keys/
    silex-packages.rsa.pub public key (committed; shipped in Silex images)
  config/
    seeds.list             seed packages; dep closure is computed from these
    skip.list              packages excluded from the closure
    recompile-override.list force-recompile list
    repack-override.list   force-repack list
    cflags.conf            compiler flags (CC, CXX, CFLAGS, LDFLAGS, etc.)
  scripts/
    build-all.sh           full pipeline: resolve -> classify -> build -> index
    build-one.sh           build a single package (recompile/repack/auto)
    resolve-deps.sh        compute transitive dep closure from seeds.list
    classify.sh            classify packages as recompile or repack
    recompile.sh           fetch source, build with Silex flags, pack as .apk
    repack.sh              download .deb, convert to .apk
    mkpkginfo.sh           Debian control -> APK .PKGINFO
    mkapk.sh               assemble .apk tar archive
    index.sh               generate and sign APKINDEX.tar.gz
    sign.sh                RSA-SHA1 signing (APKINDEX only)
    verify.sh              post-build sanity checks
  .github/workflows/
    build.yml              CI: build all packages for x86_64 and aarch64
```

---

## Signing

The `APKINDEX.tar.gz` is signed with an RSA-2048 private key. Individual
`.apk` files are not signed. Keys are stored as GitHub Actions secrets:

| Secret | Content |
|--------|---------|
| `SILEX_PKG_RSA` | RSA private key (PEM) |
| `SILEX_PKG_RSA_PUB` | RSA public key (PEM) |

The public key is committed to `keys/silex-packages.rsa.pub` and baked into
Silex images at build time.

See `SETUP.md` for key generation instructions.

---

## CI

`build.yml` triggers on push to `config/**` or `scripts/**`, on a weekly
schedule (Monday 04:00 UTC), and on `workflow_dispatch`.

Jobs:
- **x86_64** — runs on `ubuntu-latest` inside a `debian:bookworm` container;
  builds all packages, verifies, uploads artifact.
- **aarch64** — runs on `ubuntu-24.04-arm` inside `debian:bookworm`; same
  steps with `march=armv8.2-a+crypto` substituted for `x86-64-v3`.
- **deploy** — downloads both artifacts, commits `x86_64/`, `aarch64/`, and
  `keys/` back to `main`, triggering a GitHub Pages deploy.

apk-tools (static binary v2.14.4) is downloaded from the GitLab packages API
at build time since it is not available in Debian bookworm.
# Force rebuild Sat Mar 28 14:17:27 CET 2026
