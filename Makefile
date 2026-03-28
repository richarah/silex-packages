.PHONY: help update-seeds test-seeds verify-packages

help:
	@printf "silex-packages build targets:\n\n"
	@printf "  make update-seeds       Generate seeds.list from config\n"
	@printf "  make update-seeds-dry   Preview what would be generated\n"
	@printf "  make test-seeds         Validate current seeds.list\n"
	@printf "  make verify-packages    Check critical packages exist\n"
	@printf "\n"

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
