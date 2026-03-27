#!/bin/sh
# run from silex-packages root
set -e

# New scripts
cat > scripts/prep.sh << 'EOF'
#!/bin/sh
# prep.sh — resolve dependency closure and classify packages.
# Outputs repack.list and recompile.list to $REPO_ROOT/lists/
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export ARCH="${ARCH:-$(uname -m)}"

mkdir -p "$REPO_ROOT/lists"

# Compile apk-tar helper
cc -O2 -o /tmp/silex-apk-tar "$SCRIPT_DIR/apk-tar.c" ||
    { printf 'ERROR: failed to compile apk-tar.c\n' >&2; exit 1; }

CLOSURE=$(mktemp)
RECOMPILE="$REPO_ROOT/lists/recompile.list"
REPACK="$REPO_ROOT/lists/repack.list"
trap 'rm -f "$CLOSURE"' EXIT INT TERM

printf '=== resolving dependency closure ===\n'
"$SCRIPT_DIR/resolve-deps.sh" > "$CLOSURE"
printf '%d packages in closure\n' "$(wc -l < "$CLOSURE")"

printf '=== classifying packages ===\n'
"$SCRIPT_DIR/classify.sh" "$RECOMPILE" "$REPACK" < "$CLOSURE"

printf '=== prep done ===\n'
printf 'recompile: %d\n' "$(wc -l < "$RECOMPILE")"
printf 'repack:    %d\n' "$(wc -l < "$REPACK")"
EOF

cat > scripts/repack-chunk.sh << 'EOF'
#!/bin/sh
# repack-chunk.sh <chunk> <total>
# Repack every Nth package from lists/repack.list.
# Chunk is 0-indexed. Skips packages already built.
set -e
CHUNK="$1"
TOTAL="$2"

[ -n "$CHUNK" ] || { printf 'usage: repack-chunk.sh <chunk> <total>\n' >&2; exit 1; }
[ -n "$TOTAL" ] || { printf 'usage: repack-chunk.sh <chunk> <total>\n' >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export ARCH="${ARCH:-$(uname -m)}"
export REPO_DIR="${REPO_DIR:-$REPO_ROOT/$ARCH}"
export SCRIPTS_DIR="$SCRIPT_DIR"

mkdir -p "$REPO_DIR"

[ -f "$REPO_ROOT/config/cflags.conf" ] && . "$REPO_ROOT/config/cflags.conf"
export CC CXX CFLAGS CXXFLAGS LDFLAGS STRIP
export PRIVKEY PUBKEY

LIST="$REPO_ROOT/lists/repack.list"
[ -f "$LIST" ] || { printf 'repack-chunk: %s not found\n' "$LIST" >&2; exit 1; }

# Compile apk-tar helper
cc -O2 -o /tmp/silex-apk-tar "$SCRIPT_DIR/apk-tar.c" ||
    { printf 'ERROR: failed to compile apk-tar.c\n' >&2; exit 1; }

TOTAL_PKGS=$(wc -l < "$LIST")
printf 'repack-chunk: chunk %s/%s (%d total packages)\n' "$CHUNK" "$TOTAL" "$TOTAL_PKGS"

sed -n "$((CHUNK + 1))~${TOTAL}p" "$LIST" | while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if ls "$REPO_DIR/$pkg-"[0-9]*.apk >/dev/null 2>&1; then
        printf 'cached  %s\n' "$pkg"
    else
        "$SCRIPT_DIR/repack.sh" "$pkg" ||
            printf 'WARNING: repack failed for %s\n' "$pkg" >&2
    fi
done

printf 'repack-chunk %s: done\n' "$CHUNK"
EOF

cat > scripts/recompile-all.sh << 'EOF'
#!/bin/sh
# recompile-all.sh — recompile all packages in lists/recompile.list.
# Skips packages already built.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export ARCH="${ARCH:-$(uname -m)}"
export REPO_DIR="${REPO_DIR:-$REPO_ROOT/$ARCH}"
export SCRIPTS_DIR="$SCRIPT_DIR"

mkdir -p "$REPO_DIR"

[ -f "$REPO_ROOT/config/cflags.conf" ] && . "$REPO_ROOT/config/cflags.conf"
export CC CXX CFLAGS CXXFLAGS LDFLAGS STRIP
export PRIVKEY PUBKEY

LIST="$REPO_ROOT/lists/recompile.list"
[ -f "$LIST" ] || { printf 'recompile-all: %s not found\n' "$LIST" >&2; exit 1; }

# Compile apk-tar helper
cc -O2 -o /tmp/silex-apk-tar "$SCRIPT_DIR/apk-tar.c" ||
    { printf 'ERROR: failed to compile apk-tar.c\n' >&2; exit 1; }

printf '=== recompiling %d packages ===\n' "$(wc -l < "$LIST")"

while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    case "$pkg" in '#'*) continue ;; esac
    if ls "$REPO_DIR/$pkg-"[0-9]*.apk >/dev/null 2>&1; then
        printf 'cached  %s\n' "$pkg"
    else
        "$SCRIPT_DIR/recompile.sh" "$pkg" ||
            printf 'WARNING: recompile failed for %s\n' "$pkg" >&2
    fi
done < "$LIST"

printf '=== recompile done ===\n'
EOF

chmod +x scripts/prep.sh scripts/repack-chunk.sh scripts/recompile-all.sh

# Workflow
cat > .github/workflows/build.yml << 'WORKFLOW'
name: Build packages (parallel)

on:
  push:
    paths:
      - 'config/**'
      - 'scripts/**'
      - '.github/workflows/**'
  schedule:
    - cron: '0 4 * * 1'
  workflow_dispatch:

jobs:
  # ── x86_64 ──────────────────────────────────────────────

  prep-x86:
    name: Prep (x86_64)
    runs-on: ubuntu-latest
    container:
      image: debian:bookworm
    steps:
      - uses: actions/checkout@v4
      - name: Install deps
        run: |
          apt-get update -qq
          apt-get install -y --no-install-recommends \
              dpkg-dev build-essential curl ca-certificates pkg-config
      - name: Fix apt
        run: |
          echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox
          mkdir -p /var/lib/apt/lists/partial
          chown -R _apt:root /var/lib/apt/lists 2>/dev/null || true
          chmod 755 /var/lib/apt/lists
      - name: Enable deb-src
        run: |
          if [ -f /etc/apt/sources.list.d/debian.sources ]; then
            sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
          elif [ -f /etc/apt/sources.list ]; then
            grep '^deb ' /etc/apt/sources.list | sed 's/^deb /deb-src /' >> /etc/apt/sources.list
          fi
          apt-get update -qq
      - run: chmod +x scripts/*.sh
      - name: Prep
        run: scripts/prep.sh
        env:
          ARCH: x86_64
      - uses: actions/upload-artifact@v4
        with:
          name: lists-x86_64
          path: lists/

  repack-x86:
    name: Repack x86 (${{ matrix.chunk }})
    needs: prep-x86
    runs-on: ubuntu-latest
    container:
      image: debian:bookworm
    strategy:
      fail-fast: false
      matrix:
        chunk: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    steps:
      - uses: actions/checkout@v4
      - name: Install deps
        run: |
          apt-get update -qq
          apt-get install -y --no-install-recommends \
              dpkg-dev build-essential curl ca-certificates openssl pkg-config
      - name: Fix apt
        run: |
          echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox
          mkdir -p /var/lib/apt/lists/partial
          chown -R _apt:root /var/lib/apt/lists 2>/dev/null || true
          chmod 755 /var/lib/apt/lists
      - name: Enable deb-src
        run: |
          if [ -f /etc/apt/sources.list.d/debian.sources ]; then
            sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
          elif [ -f /etc/apt/sources.list ]; then
            grep '^deb ' /etc/apt/sources.list | sed 's/^deb /deb-src /' >> /etc/apt/sources.list
          fi
          apt-get update -qq
      - name: Keys
        run: |
          mkdir -p keys /tmp/silex-keys
          echo "$SILEX_PKG_RSA"     > /tmp/silex-keys/silex-packages.rsa
          echo "$SILEX_PKG_RSA_PUB" > /tmp/silex-keys/silex-packages.rsa.pub
          chmod 600 /tmp/silex-keys/silex-packages.rsa
          cp /tmp/silex-keys/silex-packages.rsa.pub keys/
        env:
          SILEX_PKG_RSA:     ${{ secrets.SILEX_PKG_RSA }}
          SILEX_PKG_RSA_PUB: ${{ secrets.SILEX_PKG_RSA_PUB }}
      - uses: actions/download-artifact@v4
        with:
          name: lists-x86_64
          path: lists/
      - run: chmod +x scripts/*.sh
      - name: Repack
        run: scripts/repack-chunk.sh ${{ matrix.chunk }} 12
        env:
          ARCH:    x86_64
          PRIVKEY: /tmp/silex-keys/silex-packages.rsa
          PUBKEY:  /tmp/silex-keys/silex-packages.rsa.pub
      - uses: actions/upload-artifact@v4
        with:
          name: repack-x86-${{ matrix.chunk }}
          path: x86_64/*.apk
          if-no-files-found: ignore

  recompile-x86:
    name: Recompile (x86_64)
    needs: prep-x86
    runs-on: ubuntu-latest
    container:
      image: debian:bookworm
    steps:
      - uses: actions/checkout@v4
      - name: Install deps
        run: |
          apt-get update -qq
          apt-get install -y --no-install-recommends \
              clang mold ninja-build cmake meson autoconf automake \
              dpkg-dev devscripts fakeroot build-essential \
              curl ca-certificates git file openssl \
              libzstd-dev libssl-dev zlib1g-dev pkg-config
      - name: Fix apt
        run: |
          echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox
          mkdir -p /var/lib/apt/lists/partial
          chown -R _apt:root /var/lib/apt/lists 2>/dev/null || true
          chmod 755 /var/lib/apt/lists
      - name: Enable deb-src
        run: |
          if [ -f /etc/apt/sources.list.d/debian.sources ]; then
            sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
          elif [ -f /etc/apt/sources.list ]; then
            grep '^deb ' /etc/apt/sources.list | sed 's/^deb /deb-src /' >> /etc/apt/sources.list
          fi
          apt-get update -qq
      - name: Keys
        run: |
          mkdir -p keys /tmp/silex-keys
          echo "$SILEX_PKG_RSA"     > /tmp/silex-keys/silex-packages.rsa
          echo "$SILEX_PKG_RSA_PUB" > /tmp/silex-keys/silex-packages.rsa.pub
          chmod 600 /tmp/silex-keys/silex-packages.rsa
          cp /tmp/silex-keys/silex-packages.rsa.pub keys/
        env:
          SILEX_PKG_RSA:     ${{ secrets.SILEX_PKG_RSA }}
          SILEX_PKG_RSA_PUB: ${{ secrets.SILEX_PKG_RSA_PUB }}
      - uses: actions/download-artifact@v4
        with:
          name: lists-x86_64
          path: lists/
      - run: chmod +x scripts/*.sh
      - name: Recompile
        run: scripts/recompile-all.sh
        env:
          ARCH:    x86_64
          PRIVKEY: /tmp/silex-keys/silex-packages.rsa
          PUBKEY:  /tmp/silex-keys/silex-packages.rsa.pub
      - uses: actions/upload-artifact@v4
        with:
          name: recompiled-x86
          path: x86_64/*.apk
          if-no-files-found: ignore

  merge-x86:
    name: Merge & index (x86_64)
    needs: [repack-x86, recompile-x86]
    runs-on: ubuntu-latest
    container:
      image: debian:bookworm
    steps:
      - uses: actions/checkout@v4
      - name: Install deps
        run: |
          apt-get update -qq
          apt-get install -y --no-install-recommends \
              curl ca-certificates openssl build-essential
      - name: Get apk-tools static
        run: |
          curl -fsSL --retry 5 \
              "https://dl-cdn.alpinelinux.org/alpine/v3.23/main/x86_64/apk-tools-static-3.0.5-r0.apk" \
              -o /tmp/apk.apk
          tar -xzf /tmp/apk.apk -C /tmp
          cp /tmp/sbin/apk.static /usr/local/bin/apk
          chmod +x /usr/local/bin/apk
      - name: Keys
        run: |
          mkdir -p keys /tmp/silex-keys /etc/apk/keys
          echo "$SILEX_PKG_RSA"     > /tmp/silex-keys/silex-packages.rsa
          echo "$SILEX_PKG_RSA_PUB" > /tmp/silex-keys/silex-packages.rsa.pub
          chmod 600 /tmp/silex-keys/silex-packages.rsa
          cp /tmp/silex-keys/silex-packages.rsa.pub keys/
          cp /tmp/silex-keys/silex-packages.rsa.pub /etc/apk/keys/
        env:
          SILEX_PKG_RSA:     ${{ secrets.SILEX_PKG_RSA }}
          SILEX_PKG_RSA_PUB: ${{ secrets.SILEX_PKG_RSA_PUB }}
      - name: Download repacked
        uses: actions/download-artifact@v4
        with:
          pattern: repack-x86-*
          path: x86_64/
          merge-multiple: true
      - name: Download recompiled
        uses: actions/download-artifact@v4
        with:
          name: recompiled-x86
          path: x86_64/
      - run: chmod +x scripts/*.sh
      - name: Index
        run: scripts/index.sh
        env:
          ARCH:     x86_64
          REPO_DIR: x86_64
          PRIVKEY:  /tmp/silex-keys/silex-packages.rsa
          PUBKEY:   /tmp/silex-keys/silex-packages.rsa.pub
      - name: Verify
        run: scripts/verify.sh x86_64
      - uses: actions/upload-artifact@v4
        with:
          name: packages-x86_64
          path: x86_64/

  # ── aarch64 ─────────────────────────────────────────────

  prep-arm:
    name: Prep (aarch64)
    runs-on: ubuntu-24.04-arm
    container:
      image: debian:bookworm
    steps:
      - uses: actions/checkout@v4
      - name: Install deps
        run: |
          apt-get update -qq
          apt-get install -y --no-install-recommends \
              dpkg-dev build-essential curl ca-certificates pkg-config
      - name: Fix apt
        run: |
          echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox
          mkdir -p /var/lib/apt/lists/partial
          chown -R _apt:root /var/lib/apt/lists 2>/dev/null || true
          chmod 755 /var/lib/apt/lists
      - name: Enable deb-src
        run: |
          if [ -f /etc/apt/sources.list.d/debian.sources ]; then
            sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
          elif [ -f /etc/apt/sources.list ]; then
            grep '^deb ' /etc/apt/sources.list | sed 's/^deb /deb-src /' >> /etc/apt/sources.list
          fi
          apt-get update -qq
      - run: chmod +x scripts/*.sh
      - name: Override march
        run: |
          sed -i 's/-march=x86-64-v3/-march=armv8.2-a+crypto/' config/cflags.conf
          sed -i 's/-fomit-frame-pointer/-fomit-frame-pointer -fno-integrated-as/' config/cflags.conf
      - name: Prep
        run: scripts/prep.sh
        env:
          ARCH: aarch64
      - uses: actions/upload-artifact@v4
        with:
          name: lists-aarch64
          path: lists/

  repack-arm:
    name: Repack arm (${{ matrix.chunk }})
    needs: prep-arm
    runs-on: ubuntu-24.04-arm
    container:
      image: debian:bookworm
    strategy:
      fail-fast: false
      matrix:
        chunk: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    steps:
      - uses: actions/checkout@v4
      - name: Install deps
        run: |
          apt-get update -qq
          apt-get install -y --no-install-recommends \
              dpkg-dev build-essential curl ca-certificates openssl pkg-config
      - name: Fix apt
        run: |
          echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox
          mkdir -p /var/lib/apt/lists/partial
          chown -R _apt:root /var/lib/apt/lists 2>/dev/null || true
          chmod 755 /var/lib/apt/lists
      - name: Enable deb-src
        run: |
          if [ -f /etc/apt/sources.list.d/debian.sources ]; then
            sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
          elif [ -f /etc/apt/sources.list ]; then
            grep '^deb ' /etc/apt/sources.list | sed 's/^deb /deb-src /' >> /etc/apt/sources.list
          fi
          apt-get update -qq
      - name: Override march
        run: |
          sed -i 's/-march=x86-64-v3/-march=armv8.2-a+crypto/' config/cflags.conf
          sed -i 's/-fomit-frame-pointer/-fomit-frame-pointer -fno-integrated-as/' config/cflags.conf
      - name: Keys
        run: |
          mkdir -p keys /tmp/silex-keys
          echo "$SILEX_PKG_RSA"     > /tmp/silex-keys/silex-packages.rsa
          echo "$SILEX_PKG_RSA_PUB" > /tmp/silex-keys/silex-packages.rsa.pub
          chmod 600 /tmp/silex-keys/silex-packages.rsa
          cp /tmp/silex-keys/silex-packages.rsa.pub keys/
        env:
          SILEX_PKG_RSA:     ${{ secrets.SILEX_PKG_RSA }}
          SILEX_PKG_RSA_PUB: ${{ secrets.SILEX_PKG_RSA_PUB }}
      - uses: actions/download-artifact@v4
        with:
          name: lists-aarch64
          path: lists/
      - run: chmod +x scripts/*.sh
      - name: Repack
        run: scripts/repack-chunk.sh ${{ matrix.chunk }} 12
        env:
          ARCH:    aarch64
          PRIVKEY: /tmp/silex-keys/silex-packages.rsa
          PUBKEY:  /tmp/silex-keys/silex-packages.rsa.pub
      - uses: actions/upload-artifact@v4
        with:
          name: repack-arm-${{ matrix.chunk }}
          path: aarch64/*.apk
          if-no-files-found: ignore

  recompile-arm:
    name: Recompile (aarch64)
    needs: prep-arm
    runs-on: ubuntu-24.04-arm
    container:
      image: debian:bookworm
    steps:
      - uses: actions/checkout@v4
      - name: Install deps
        run: |
          apt-get update -qq
          apt-get install -y --no-install-recommends \
              clang mold ninja-build cmake meson autoconf automake \
              dpkg-dev devscripts fakeroot build-essential \
              curl ca-certificates git file openssl \
              libzstd-dev libssl-dev zlib1g-dev pkg-config
      - name: Fix apt
        run: |
          echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox
          mkdir -p /var/lib/apt/lists/partial
          chown -R _apt:root /var/lib/apt/lists 2>/dev/null || true
          chmod 755 /var/lib/apt/lists
      - name: Enable deb-src
        run: |
          if [ -f /etc/apt/sources.list.d/debian.sources ]; then
            sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
          elif [ -f /etc/apt/sources.list ]; then
            grep '^deb ' /etc/apt/sources.list | sed 's/^deb /deb-src /' >> /etc/apt/sources.list
          fi
          apt-get update -qq
      - name: Override march
        run: |
          sed -i 's/-march=x86-64-v3/-march=armv8.2-a+crypto/' config/cflags.conf
          sed -i 's/-fomit-frame-pointer/-fomit-frame-pointer -fno-integrated-as/' config/cflags.conf
      - name: Keys
        run: |
          mkdir -p keys /tmp/silex-keys
          echo "$SILEX_PKG_RSA"     > /tmp/silex-keys/silex-packages.rsa
          echo "$SILEX_PKG_RSA_PUB" > /tmp/silex-keys/silex-packages.rsa.pub
          chmod 600 /tmp/silex-keys/silex-packages.rsa
          cp /tmp/silex-keys/silex-packages.rsa.pub keys/
        env:
          SILEX_PKG_RSA:     ${{ secrets.SILEX_PKG_RSA }}
          SILEX_PKG_RSA_PUB: ${{ secrets.SILEX_PKG_RSA_PUB }}
      - uses: actions/download-artifact@v4
        with:
          name: lists-aarch64
          path: lists/
      - run: chmod +x scripts/*.sh
      - name: Recompile
        run: scripts/recompile-all.sh
        env:
          ARCH:    aarch64
          PRIVKEY: /tmp/silex-keys/silex-packages.rsa
          PUBKEY:  /tmp/silex-keys/silex-packages.rsa.pub
      - uses: actions/upload-artifact@v4
        with:
          name: recompiled-arm
          path: aarch64/*.apk
          if-no-files-found: ignore

  merge-arm:
    name: Merge & index (aarch64)
    needs: [repack-arm, recompile-arm]
    runs-on: ubuntu-24.04-arm
    container:
      image: debian:bookworm
    steps:
      - uses: actions/checkout@v4
      - name: Install deps
        run: |
          apt-get update -qq
          apt-get install -y --no-install-recommends \
              curl ca-certificates openssl build-essential
      - name: Get apk-tools static
        run: |
          curl -fsSL --retry 5 \
              "https://dl-cdn.alpinelinux.org/alpine/v3.23/main/aarch64/apk-tools-static-3.0.5-r0.apk" \
              -o /tmp/apk.apk
          tar -xzf /tmp/apk.apk -C /tmp
          cp /tmp/sbin/apk.static /usr/local/bin/apk
          chmod +x /usr/local/bin/apk
      - name: Keys
        run: |
          mkdir -p keys /tmp/silex-keys /etc/apk/keys
          echo "$SILEX_PKG_RSA"     > /tmp/silex-keys/silex-packages.rsa
          echo "$SILEX_PKG_RSA_PUB" > /tmp/silex-keys/silex-packages.rsa.pub
          chmod 600 /tmp/silex-keys/silex-packages.rsa
          cp /tmp/silex-keys/silex-packages.rsa.pub keys/
          cp /tmp/silex-keys/silex-packages.rsa.pub /etc/apk/keys/
        env:
          SILEX_PKG_RSA:     ${{ secrets.SILEX_PKG_RSA }}
          SILEX_PKG_RSA_PUB: ${{ secrets.SILEX_PKG_RSA_PUB }}
      - name: Download repacked
        uses: actions/download-artifact@v4
        with:
          pattern: repack-arm-*
          path: aarch64/
          merge-multiple: true
      - name: Download recompiled
        uses: actions/download-artifact@v4
        with:
          name: recompiled-arm
          path: aarch64/
      - run: chmod +x scripts/*.sh
      - name: Index
        run: scripts/index.sh
        env:
          ARCH:     aarch64
          REPO_DIR: aarch64
          PRIVKEY:  /tmp/silex-keys/silex-packages.rsa
          PUBKEY:   /tmp/silex-keys/silex-packages.rsa.pub
      - name: Verify
        run: scripts/verify.sh aarch64
      - uses: actions/upload-artifact@v4
        with:
          name: packages-aarch64
          path: aarch64/

  # ── test & deploy ───────────────────────────────────────

  test:
    name: Test (x86_64)
    needs: merge-x86
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: packages-x86_64
          path: x86_64/
      - name: Get apk
        run: |
          curl -fsSL --retry 5 \
              "https://dl-cdn.alpinelinux.org/alpine/v3.23/main/x86_64/apk-tools-static-3.0.5-r0.apk" \
              -o /tmp/apk.apk
          tar -xzf /tmp/apk.apk -C /tmp
          sudo cp /tmp/sbin/apk.static /usr/local/bin/apk
          sudo chmod +x /usr/local/bin/apk
      - name: Test
        run: |
          set -e
          R=/tmp/pkgroot
          mkdir -p "$R/etc/apk/keys" "$R/var/cache/apk" \
                   "$R/var/lib/apk" "$R/lib/apk/db"
          cp keys/*.rsa.pub "$R/etc/apk/keys/"
          printf 'file://%s\n' "$GITHUB_WORKSPACE" > "$R/etc/apk/repositories"
          printf 'x86_64\n' > "$R/etc/apk/arch"
          /usr/local/bin/apk --root "$R" add --initdb --usermode
          /usr/local/bin/apk --root "$R" --allow-untrusted update
          count=$(/usr/local/bin/apk --root "$R" --allow-untrusted list --available 2>/dev/null | wc -l || echo 0)
          printf 'index: %d packages\n' "$count"
          [ "$count" -gt 50 ] || { printf 'FAIL: expected >50\n'; exit 1; }
          /usr/local/bin/apk extract --allow-untrusted --destination "$R" \
              x86_64/zlib1g-dev-*.x86_64.apk \
              x86_64/libffi-dev-*.x86_64.apk \
              x86_64/bzip2-*.x86_64.apk
          test -f "$R/usr/include/zlib.h" || { printf 'FAIL: zlib.h\n'; exit 1; }
          test -f "$R/usr/include/ffi.h"  || { printf 'FAIL: ffi.h\n';  exit 1; }
          test -f "$R/bin/bzip2"          || { printf 'FAIL: bzip2\n';  exit 1; }
          printf 'PASS\n'

  deploy:
    name: Deploy to Pages
    needs: [merge-x86, merge-arm, test]
    runs-on: ubuntu-latest
    permissions:
      pages: write
      id-token: write
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: packages-x86_64
          path: x86_64/
      - uses: actions/download-artifact@v4
        with:
          name: packages-aarch64
          path: aarch64/
      - uses: actions/jekyll-build-pages@v1
        with:
          source: ./
          destination: ./_site
      - name: Copy packages
        run: |
          mkdir -p ./_site/x86_64 ./_site/aarch64 ./_site/keys
          cp -r x86_64/* ./_site/x86_64/
          cp -r aarch64/* ./_site/aarch64/
          cp -r keys/* ./_site/keys/
      - uses: actions/configure-pages@v5
      - uses: actions/upload-pages-artifact@v3
        with:
          path: ./_site
      - name: Deploy
        id: deployment
        uses: actions/deploy-pages@v4
WORKFLOW

printf 'done. 3 new scripts + workflow replaced.\n'
printf 'git add -A && git commit -m "parallel build: 12 repack runners per arch" && git push\n'
