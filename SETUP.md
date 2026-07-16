# Setting up silex-packages from scratch

Everything runs in a `debian:bookworm` container. No abuild, no Alpine SDK,
no APKBUILDs. The build tools are standard Debian packages.

## 1. Generate signing keys

Keys must be RSA-2048 PEM files. Generate them once with openssl:

```sh
mkdir -p keys
openssl genrsa -out keys/silex-packages.rsa 2048
openssl rsa -in keys/silex-packages.rsa -pubout -out keys/silex-packages.rsa.pub
chmod 600 keys/silex-packages.rsa
```

- `keys/silex-packages.rsa` — private key. **Never commit this.**
- `keys/silex-packages.rsa.pub` — public key. Commit it. Shipped in Silex images.

The `.gitignore` includes `*.rsa` (private) and `!*.rsa.pub` (exception for
public). Verify with `git status` before committing.

## 2. Add secrets to GitHub

Go to the silex-packages repo:
Settings -> Secrets and variables -> Actions -> New repository secret.

- `SILEX_PKG_RSA`: paste the full contents of `keys/silex-packages.rsa`,
  including the `-----BEGIN RSA PRIVATE KEY-----` and
  `-----END RSA PRIVATE KEY-----` lines.

- `SILEX_PKG_RSA_PUB`: paste the full contents of `keys/silex-packages.rsa.pub`.

## 3. Commit the public key

```sh
git add keys/silex-packages.rsa.pub
git commit -m "keys: add silex-packages public key"
git push
```

CI reads the public key from `keys/` at build time and commits it back with
the packages so it is accessible at the repo URL.

## 4. Test locally

Run the full pipeline in a Debian bookworm container to verify everything works
before pushing to CI:

```sh
docker run --rm -it \
    -v "$PWD:/work" -w /work \
    debian:bookworm sh -c '
        apt-get update -qq
        apt-get install -y --no-install-recommends \
            clang mold ninja-build cmake meson autoconf automake \
            dpkg-dev devscripts fakeroot build-essential \
            curl ca-certificates git file openssl

        # Enable deb-src
        sed -i "s/^Types: deb$/Types: deb deb-src/" \
            /etc/apt/sources.list.d/debian.sources
        apt-get update -qq

        # Install apk-tools static binary
        curl -fsSL \
            "https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic//v2.14.4/x86_64/apk.static" \
            -o /usr/local/bin/apk
        chmod +x /usr/local/bin/apk

        # Set up keys
        mkdir -p /tmp/silex-keys
        cp /work/keys/silex-packages.rsa     /tmp/silex-keys/
        cp /work/keys/silex-packages.rsa.pub /tmp/silex-keys/
        chmod 600 /tmp/silex-keys/silex-packages.rsa

        chmod +x /work/scripts/*.sh
        ARCH=x86_64 \
        PRIVKEY=/tmp/silex-keys/silex-packages.rsa \
        PUBKEY=/tmp/silex-keys/silex-packages.rsa.pub \
        /work/scripts/build-all.sh
    '
```

For a quick test of just one package:

```sh
docker run --rm -it \
    -v "$PWD:/work" -w /work \
    debian:bookworm sh -c '
        apt-get update -qq
        apt-get install -y --no-install-recommends \
            dpkg-dev devscripts fakeroot build-essential curl ca-certificates file openssl
        curl -fsSL \
            "https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic//v2.14.4/x86_64/apk.static" \
            -o /usr/local/bin/apk && chmod +x /usr/local/bin/apk
        chmod +x /work/scripts/*.sh
        export ARCH=x86_64
        export REPO_DIR=/work/x86_64
        export SCRIPTS_DIR=/work/scripts
        /work/scripts/repack.sh zlib1g-dev
        apk index --allow-untrusted -o /work/x86_64/APKINDEX.tar.gz /work/x86_64/*.apk
    '
```

## 5. Enable GitHub Pages

1. Push the public key, config, and scripts.
2. Go to repo Settings -> Pages.
3. Source: **"GitHub Actions"**.
4. Save.

The source must be "GitHub Actions", not "Deploy from a branch": `build.yml`
publishes with `actions/upload-pages-artifact` + `actions/deploy-pages`, which
only works when Pages is set to the Actions source. Pointing it at a branch
leaves the deploy job failing and the site serving whatever is on that branch.

Repository URL — this is what goes in `/etc/apk/repositories`:

```
https://richarah.github.io/silex-packages
```

apk derives the rest itself, fetching the index from
`https://richarah.github.io/silex-packages/<arch>/APKINDEX.tar.gz`. Do not put
the architecture in the repositories line; apk would then look for
`.../x86_64/x86_64/APKINDEX.tar.gz` and 404.

The signing key is published at
`https://richarah.github.io/silex-packages/keys/silex-packages.rsa.pub`.

## 6. Trigger CI

Push any change to `config/**` or `scripts/**` to trigger a build. Or use:

```sh
gh workflow run build.yml
```

The workflow builds both architectures in parallel, signs the index, and
publishes the `.apk` files plus `APKINDEX.tar.gz` to GitHub Pages.

### CI runs entirely on GitHub-hosted runners

No self-hosted runner is required. `build.yml` runs one job per architecture, on
a runner of that architecture:

| job | runner | notes |
|-----|--------|-------|
| `build (x86_64)` | `ubuntu-latest` | native |
| `build (aarch64)` | `ubuntu-24.04-arm` | native — free ARM runner for public repos |
| `sign-indexes` | `ubuntu-latest` | index-only, needs no build capacity |
| `deploy-pages` | `ubuntu-latest` | |

The two architectures build concurrently. Measured on the migration run: aarch64
in ~34 min (2223 MB of packages), the whole pipeline — both arches, sign, and
deploy — in ~48 min wall-clock.

It fits a hosted runner (4 vCPU / 16 GB / ~14 GB disk / 6 h) because:

- **Splitting by arch halves the per-job output** — ~2.2 GB rather than ~4.8 GB.
- **`recompile.sh` sizes its own parallelism** from `MemAvailable` and `nproc`
  (`MEM_GB/6`, capped at `nproc/2`), so it self-limits to ~2 concurrent compiles
  on a hosted runner instead of the 6/arch it picks on a large box. No OOM, and
  nothing to tune per runner.
- **Time was never the constraint.** The old single self-hosted job spent ~47 min
  building both arches; most of the rest of its ~1h47m was uploading one ~5 GB
  artifact. Per-arch artifacts are ~2.2 GB and upload concurrently.

aarch64 is *faster* here than it was on the old self-hosted x86 box, which ran it
under `qemu-user-static`. Native ARM removes the emulation entirely, and there is
no `qemu` in the build image any more.

#### Building locally instead

The Makefile targets are unchanged, so a big machine can still do the whole thing
directly — useful for iterating without waiting on CI:

```sh
make -j "$(nproc)" build      # both arches (aarch64 needs qemu-user-static)
make build-x86                # one arch only
```

Note that building aarch64 on an x86 host requires `qemu-user-static` and is
substantially slower than the native ARM runner CI now uses.

A self-hosted runner remains possible (`runs-on: [self-hosted, Linux, X64]`) if
you want CI on your own hardware, but it is no longer needed, and it carries two
failure modes worth knowing: a runner started as a foreground `./run.sh` dies
with its shell session (or when the machine sleeps), stalling in-flight jobs
while GitHub still reports it `busy` — install it via `sudo ./svc.sh install` to
survive that — and the jobs run in containers, so a stopped Docker daemon on the
host fails them immediately with `docker: command not found`.

## 7. Verify from a container

Once CI has run and Pages has deployed:

```sh
docker run --rm -it ghcr.io/richarah/silex:slim sh -c '
    apk update
    apk add zlib1g-dev
'
```

Or from a plain Alpine/Wolfi container with the key and repo added manually
(see README.md for the setup commands).

## 8. Managing package selection (ongoing)

The repository is built from packages listed in `config/seeds.list`. The dependency
resolver automatically computes the transitive closure via `resolve-deps.sh`.

### Finding missing dependencies

When a new test fails due to missing packages, use the automated dependency analysis:

```sh
./scripts/find-missing-deps.sh          # Show what's missing
./scripts/find-missing-deps.sh --auto-add  # Add missing packages to seeds.list
```

This scans the packages you've already selected and identifies unmet dependencies.
It's fast because it only analyzes what you have, not the entire Debian archive.

### Validating package selection

After updating `seeds.list`, validate the result:

```sh
./scripts/test-seeds.sh --verbose
```

This checks:
- All packages exist in Debian Bookworm
- Total repository size is within limits (~4GB)
- Critical packages (gcc, curl, etc.) are present
- No obvious bloat (fonts, games, docs) slipped in

### Configuration

Edit `config/pkg-selection.conf` to adjust:
- Maximum repository size in GB
- Which package priorities to include (required, important, standard, optional)
- Which optional categories to include (build tools, languages, etc.)
- Exclusion patterns (docs, debug symbols, GUI libraries, etc.)

Then regenerate from scratch:

```sh
./scripts/generate-seeds.sh              # Generate and show what would be added
./scripts/generate-seeds.sh --auto-add   # Auto-add all selected packages
```

**KISS approach**: Start with `find-missing-deps.sh` when a package is missing.
Use `generate-seeds.sh` only when you want a complete package refresh.

## Signing design

Individual `.apk` files are **unsigned**. Only `APKINDEX.tar.gz` is signed.

This is intentional: `apk index --allow-untrusted` (used to generate the
index from unsigned packages) works correctly, whereas prepending a gzip
signature stream to individual packages causes `apk index` to report
`BAD archive` when it tries to read `.PKGINFO` from the signed packages'
second gzip stream.

Security is maintained: apk verifies each downloaded package's SHA256
checksum against the signed APKINDEX. A tampered `.apk` will not match
the index checksum.

## Key rotation

1. Generate a new keypair (step 1 above).
2. Update GitHub secrets `SILEX_PKG_RSA` and `SILEX_PKG_RSA_PUB`.
3. Commit the new public key to `keys/silex-packages.rsa.pub`.
4. Rebuild the Silex base image so the new public key is baked in.
5. Run CI to re-sign the APKINDEX with the new key.

Old containers that have the previous public key in `/etc/apk/keys/` will
no longer trust the repository until they are rebuilt or the old key is
added alongside the new one.
