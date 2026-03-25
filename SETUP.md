# Setting up silex-packages from scratch

Everything here runs on a Debian/Ubuntu host using Alpine containers.
You never install abuild on your host. Everything happens inside
`alpine:3.21` containers with your working directory mounted.

## 1. Generate signing keys

apk packages must be signed. Generate a keypair once:

```sh
mkdir -p keys

docker run --rm -it -v "$PWD/keys:/keys" alpine:3.21 sh -c '
    apk add abuild
    abuild-keygen -a -n
    cp /root/.abuild/*.rsa /keys/
    cp /root/.abuild/*.rsa.pub /keys/
'
```

You now have two files in `keys/`:
- `*.rsa` — private key. NEVER commit this.
- `*.rsa.pub` — public key. Commit this. Goes in the Silex image.

The filenames look like `-69c32bcf.rsa`. That's normal. Alpine
names them with a hash fragment.

## 2. Add secrets to GitHub

Go to the silex-packages repo:
Settings -> Secrets and variables -> Actions -> New repository secret.

- `SILEX_PKG_RSA`: paste the ENTIRE contents of `keys/*.rsa`,
  including the `-----BEGIN RSA PRIVATE KEY-----` and
  `-----END RSA PRIVATE KEY-----` lines.

- `SILEX_PKG_RSA_PUB`: paste the ENTIRE contents of `keys/*.rsa.pub`.

These are repository secrets, not environment secrets.

The main silex repo does NOT need secrets. It only needs the
public key committed as a file.

## 3. Set up .gitignore

```
x86_64/*.apk
aarch64/*.apk
x86_64/APKINDEX.tar.gz
aarch64/APKINDEX.tar.gz
*/src/
*/pkg/
tmp/
*.rsa
!*.rsa.pub
/root/.abuild/
*.tar.gz
*.tar.xz
*.tar.bz2
.DS_Store
```

The `!*.rsa.pub` exception keeps the public key tracked.
Verify with `git status` that `keys/*.rsa.pub` shows as tracked
and `keys/*.rsa` does not.

## 4. Generate checksums

APKBUILDs ship with `sha512sums="SKIP"` until you run this.
abuild checksum downloads each source tarball and writes the
real hash into the APKBUILD.

```sh
docker run --rm -it -v "$PWD:/work" -w /work alpine:3.21 sh -c '
    apk add abuild
    cd /work
    scripts/gen-checksums.sh
'
```

This downloads ~500MB of source tarballs. Takes a few minutes.
After this, every APKBUILD has real sha512sums. Commit the
updated APKBUILDs.

If a URL 404s (upstream moved the tarball), find the new URL.
Prefer GitHub Releases URLs — they don't move. For example,
zlib.net deletes old versions. Use:
```
https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz
```
instead of:
```
https://zlib.net/zlib-1.3.2.tar.gz
```

## 5. Build one package (test)

Always test one package locally before pushing to CI.

```sh
docker run --rm -it -v "$PWD:/work" -w /work alpine:3.21 sh -c '
    apk add abuild alpine-sdk sudo
    adduser -D builder
    addgroup builder abuild
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    mkdir -p /home/builder/.abuild
    cp /work/keys/*.rsa /home/builder/.abuild/
    cp /work/keys/*.rsa.pub /home/builder/.abuild/
    KEYFILE=$(ls /home/builder/.abuild/*.rsa | grep -v pub | head -1)
    echo "PACKAGER_PRIVKEY=$KEYFILE" > /home/builder/.abuild/abuild.conf
    chown -R builder:builder /home/builder/.abuild /work
    cp /work/keys/*.rsa.pub /etc/apk/keys/
    su builder -c "cd /work/aports/zlib && abuild checksum && abuild -r -P /work"
'
```

Explanation of what this does:
- Installs abuild and alpine-sdk (compiler, make, etc)
- Creates a non-root user (abuild refuses to run as root)
- Adds builder to abuild group
- Gives builder passwordless sudo (abuild needs it internally)
- Copies your signing key and tells abuild where it is
  via PACKAGER_PRIVKEY in abuild.conf
- Copies public key to /etc/apk/keys/ (so apk trusts packages
  signed with your key)
- Runs `abuild checksum` (downloads source, writes hash)
- Runs `abuild -r -P /work` (builds package, outputs to /work)

If it works, you'll see a `.apk` file in `x86_64/`.

Common failures:
- "Do not run abuild as root" — you forgot the builder user
- "No private key found" — PACKAGER_PRIVKEY not set in abuild.conf
- "missing in checksums" — run `abuild checksum` first
- "404 Not Found" — upstream moved the tarball, update the URL
- "checksum failed" — the tarball changed upstream, verify and
  update sha512sums

## 6. Build all packages

Same container setup, but run build-all.sh instead:

```sh
docker run --rm -it -v "$PWD:/work" -w /work alpine:3.21 sh -c '
    apk add abuild alpine-sdk sudo
    adduser -D builder
    addgroup builder abuild
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    mkdir -p /home/builder/.abuild
    cp /work/keys/*.rsa /home/builder/.abuild/
    cp /work/keys/*.rsa.pub /home/builder/.abuild/
    KEYFILE=$(ls /home/builder/.abuild/*.rsa | grep -v pub | head -1)
    echo "PACKAGER_PRIVKEY=$KEYFILE" > /home/builder/.abuild/abuild.conf
    chown -R builder:builder /home/builder/.abuild /work
    cp /work/keys/*.rsa.pub /etc/apk/keys/
    su builder -c "cd /work && scripts/build-all.sh"
'
```

This takes a long time. gcc alone is multi-hour. For local testing,
build individual packages with build-one.sh:

```sh
su builder -c "cd /work && scripts/build-one.sh zlib"
```

## 7. Generate index

After building, generate the APKINDEX:

```sh
docker run --rm -it -v "$PWD:/work" -w /work alpine:3.21 sh -c '
    apk add abuild
    mkdir -p /home/builder/.abuild
    cp /work/keys/*.rsa /home/builder/.abuild/
    KEYFILE=$(ls /home/builder/.abuild/*.rsa | grep -v pub | head -1)
    echo "PACKAGER_PRIVKEY=$KEYFILE" > /home/builder/.abuild/abuild.conf
    cd /work
    scripts/index.sh
'
```

This creates `x86_64/APKINDEX.tar.gz` (signed).

## 8. Enable GitHub Pages

1. Push everything (APKBUILDs, keys/*.rsa.pub, scripts, CI workflow)
2. Go to repo Settings -> Pages
3. Source: "Deploy from a branch"
4. Branch: main, folder: / (root)
5. Save

URL: `https://richarah.github.io/silex-packages/`

apk fetches from:
`https://richarah.github.io/silex-packages/x86_64/`

## 9. Test from a Silex container

The silex:slim image has the silex-packages public key and repository
URL baked in. No manual key or repo setup needed:

```sh
docker run --rm -it ghcr.io/richarah/silex:slim sh -c '
    apk update
    apk add libssl-dev
'
```

If `apk add libssl-dev` resolves to `openssl-dev` (via `provides=`)
and installs successfully, the whole pipeline works.

If testing a locally built image before publishing:

```sh
docker run --rm -it silex:slim sh -c '
    apk update
    apk add libssl-dev
'
```

The key and repo are already in the image at:
- `/etc/apk/keys/-69c32c6d.rsa.pub`
- `/etc/apk/repositories` (silex-packages listed before Wolfi)

## 10. CI handles this from now on

Once CI is green, you don't need to build locally anymore.
Push an APKBUILD change, CI builds it, generates the index,
commits the .apk files, Pages deploys. The local build steps
above are only for:
- Initial setup (this document)
- Debugging a failing package
- Testing before pushing

## Warning: do not chown /work inside the container

The /work mount is your host directory. If you chown it to the
builder user inside the container, your host user loses write
access. If this happens:

```sh
docker run --rm -v "$PWD:/work" alpine:3.21 chown -R $(id -u):$(id -g) /work
```

Only chown /home/builder/.abuild. abuild-sudo handles the rest.

## Quick reference: the container one-liner

For any abuild operation, this is the skeleton:

```sh
docker run --rm -it -v "$PWD:/work" -w /work alpine:3.21 sh -c '
    apk add abuild alpine-sdk sudo
    adduser -D builder && addgroup builder abuild
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    mkdir -p /home/builder/.abuild
    cp /work/keys/*.rsa /home/builder/.abuild/
    cp /work/keys/*.rsa.pub /home/builder/.abuild/
    KEYFILE=$(ls /home/builder/.abuild/*.rsa | grep -v pub | head -1)
    echo "PACKAGER_PRIVKEY=$KEYFILE" > /home/builder/.abuild/abuild.conf
    chown -R builder:builder /home/builder/.abuild /work
    cp /work/keys/*.rsa.pub /etc/apk/keys/
    su builder -c "YOUR_COMMAND_HERE"
'
```

Replace YOUR_COMMAND_HERE with whatever you need:
- `cd /work/aports/zlib && abuild checksum` — update checksum
- `cd /work/aports/zlib && abuild -r -P /work` — build one package
- `cd /work && scripts/build-all.sh` — build everything
- `cd /work && scripts/build-one.sh openssl` — build one by name

## Why Alpine containers for local builds

abuild is an Alpine tool. It's not in Debian or Ubuntu. For local
builds you need an Alpine container.

CI runs inside `cgr.dev/chainguard/wolfi-base:latest`, which also has
abuild available from the Wolfi repo. Wolfi is glibc-based (same as
silex:slim's runtime), so packages built there link correctly. Local
development uses Alpine containers because they don't require a
registry login and are simpler to invoke ad-hoc.
