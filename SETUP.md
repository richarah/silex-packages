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
3. Source: "Deploy from a branch", Branch: `main`, Folder: `/`.
4. Save.

URL: `https://richarah.github.io/silex-packages/`

apk fetches the index from:
`https://richarah.github.io/silex-packages/x86_64/`

## 6. Trigger CI

Push any change to `config/**` or `scripts/**` to trigger a build. Or use:

```sh
gh workflow run build.yml
```

The workflow builds both architectures in parallel, verifies the output, and
commits the resulting `.apk` files and `APKINDEX.tar.gz` back to `main`.

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
