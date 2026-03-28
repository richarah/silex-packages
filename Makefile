# silex-packages Makefile - parallel build using all cores
# Usage: make -j N build
#        N = number of parallel jobs (default: auto-detect)

.PHONY: help build build-x86 build-arm prep prep-x86 prep-arm \
        repack repack-x86 repack-arm \
        recompile recompile-x86 recompile-arm \
        merge merge-x86 merge-arm sign-indexes clean \
        update-seeds test-seeds verify-packages

SHELL := bash
REPO_ROOT := $(shell pwd)
SCRIPTS_DIR := $(REPO_ROOT)/scripts
ARCH ?= x86_64
TOTAL_CHUNKS := 12

# Keys - set via environment or GitHub secrets
PRIVKEY ?= /tmp/silex-keys/silex-packages.rsa
PUBKEY ?= /tmp/silex-keys/silex-packages.rsa.pub

# Export for scripts
export PRIVKEY PUBKEY SCRIPTS_DIR

help:
	@printf "silex-packages build targets:\n\n"
	@printf "Build:\n"
	@printf "  make build              Full build (x86_64 + aarch64)\n"
	@printf "  make build-x86          Build x86_64 only\n"
	@printf "  make build-arm          Build aarch64 only\n"
	@printf "  make -j 32 build        Parallel build with 32 jobs\n"
	@printf "\nPhases:\n"
	@printf "  make prep               Prep both architectures\n"
	@printf "  make repack             Repack all chunks (all arches)\n"
	@printf "  make recompile          Recompile (all arches)\n"
	@printf "  make merge              Merge & index (all arches)\n"
	@printf "  make sign-indexes       Sign APKINDEX files\n"
	@printf "\nPackage selection:\n"
	@printf "  make update-seeds       Generate seeds.list from config\n"
	@printf "  make test-seeds         Validate current seeds.list\n"
	@printf "  make verify-packages    Check critical packages exist\n"
	@printf "\nCleanup:\n"
	@printf "  make clean              Remove build artifacts\n"
	@printf "\n"

# ── Main targets ────────────────────────────────────────────

build: build-x86 build-arm
	@printf "\n✓ Build complete (x86_64 + aarch64)\n"

build-x86: prep-x86 repack-x86 recompile-x86 merge-x86
	@printf "✓ x86_64 build complete\n"

build-arm: prep-arm repack-arm recompile-arm merge-arm
	@printf "✓ aarch64 build complete\n"

# ── Prep phase ────────────────────────────────────────────

prep: prep-x86 prep-arm
	@printf "✓ Prep complete\n"

prep-x86:
	@mkdir -p "$(REPO_ROOT)/x86_64"
	@printf "[prep] Generating recompile layers...\n"
	@cd "$(REPO_ROOT)" && ./scripts/gen-layers.sh
	@printf "[prep] x86_64 preprocessing...\n"
	@cd "$(REPO_ROOT)" && ARCH=x86_64 ./scripts/prep.sh

prep-arm:
	@mkdir -p "$(REPO_ROOT)/aarch64"
	@printf "[prep] aarch64 preprocessing...\n"
	@cd "$(REPO_ROOT)" && ARCH=aarch64 ./scripts/prep.sh

# ── Repack phase - all chunks in parallel ────────────────────

repack: repack-x86 repack-arm
	@printf "✓ Repacking complete\n"

repack-x86: prep-x86
	@printf "[repack] Starting x86_64 chunks (0-11)...\n"
	@cd "$(REPO_ROOT)" && for chunk in {0..11}; do \
		( ARCH=x86_64 REPO_DIR=$(REPO_ROOT)/x86_64 $(SCRIPTS_DIR)/repack-chunk.sh $$chunk $(TOTAL_CHUNKS) ) & \
	done; \
	wait
	@printf "✓ x86_64 repacking complete\n"

repack-arm: prep-arm
	@printf "[repack] Starting aarch64 chunks (0-11) via QEMU...\n"
	@cd "$(REPO_ROOT)" && for chunk in {0..11}; do \
		( ARCH=aarch64 REPO_DIR=$(REPO_ROOT)/aarch64 $(SCRIPTS_DIR)/repack-chunk.sh $$chunk $(TOTAL_CHUNKS) ) & \
	done; \
	wait
	@printf "✓ aarch64 repacking complete\n"

# ── Recompile phase - layers in sequence, chunks in parallel ────────────

recompile: recompile-x86 recompile-arm
	@printf "✓ Recompilation complete\n"

recompile-x86: repack-x86
	@printf "[recompile] x86_64 layer 0...\n"
	@cd "$(REPO_ROOT)" && ARCH=x86_64 REPO_DIR=$(REPO_ROOT)/x86_64 $(SCRIPTS_DIR)/recompile-layer.sh 0
	@printf "[recompile] x86_64 layer 1...\n"
	@cd "$(REPO_ROOT)" && ARCH=x86_64 REPO_DIR=$(REPO_ROOT)/x86_64 $(SCRIPTS_DIR)/recompile-layer.sh 1

recompile-arm: repack-arm
	@printf "[recompile] aarch64 layer 0...\n"
	@cd "$(REPO_ROOT)" && ARCH=aarch64 REPO_DIR=$(REPO_ROOT)/aarch64 $(SCRIPTS_DIR)/recompile-layer.sh 0
	@printf "[recompile] aarch64 layer 1...\n"
	@cd "$(REPO_ROOT)" && ARCH=aarch64 REPO_DIR=$(REPO_ROOT)/aarch64 $(SCRIPTS_DIR)/recompile-layer.sh 1

# ── Merge & index phase ────────────────────────────────────────

merge: merge-x86 merge-arm
	@printf "✓ Merge complete\n"

merge-x86: recompile-x86
	@printf "[merge] x86_64 indexing...\n"
	@cd "$(REPO_ROOT)" && ARCH=x86_64 REPO_DIR=$(REPO_ROOT)/x86_64 $(SCRIPTS_DIR)/index.sh x86_64
	@printf "[merge] x86_64 verifying...\n"
	@cd "$(REPO_ROOT)" && $(SCRIPTS_DIR)/verify.sh x86_64

merge-arm: recompile-arm
	@printf "[merge] aarch64 indexing...\n"
	@cd "$(REPO_ROOT)" && ARCH=aarch64 REPO_DIR=$(REPO_ROOT)/aarch64 $(SCRIPTS_DIR)/index.sh aarch64
	@printf "[merge] aarch64 verifying...\n"
	@cd "$(REPO_ROOT)" && $(SCRIPTS_DIR)/verify.sh aarch64

# ── Signing phase (requires Alpine container) ────────────────────────────────────────────

sign-indexes:
	@printf "ERROR: Signing requires Alpine + abuild (run in CI or Alpine container)\n" >&2
	@printf "For CI: Use 'make build' then GitHub Actions handles signing\n" >&2
	@exit 1

# ── Package selection ────────────────────────────────────────

update-seeds:
	./scripts/generate-seeds.sh --verbose

update-seeds-dry:
	./scripts/generate-seeds.sh --dry-run --verbose

test-seeds:
	./scripts/test-seeds.sh --verbose

verify-packages:
	@printf "Checking critical packages...\n"
	@for pkg in libssl3 libcurl4 zlib1g libc6 libgcc-s1 libstdc++6 curl wget git gcc make; do \
		if apt-cache show $$pkg >/dev/null 2>&1; then \
			printf "  ✓ %s\n" $$pkg; \
		else \
			printf "  ✗ %s\n" $$pkg; \
		fi; \
	done

# ── Cleanup ──────────────────────────────────────────────────

clean:
	@printf "Removing build artifacts...\n"
	@rm -rf x86_64/ aarch64/
	@rm -f /tmp/silex-apk-tar
	@printf "✓ Cleaned\n"
