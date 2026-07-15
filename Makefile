SWIFTC = xcrun swiftc
SWIFT_FLAGS = -framework Virtualization -O -Xcc -fobjc-arc
BUILD_DIR = build
PRODUCT = $(BUILD_DIR)/msl
VERSION_FILE = Sources/Version.swift

# VERSION is auto-generated from the latest git tag.
# Falls back to 0.0.0-dev if no tags exist (e.g. fresh clone in CI).
VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0-dev")
VERSION_NEXT := $(shell IFS='.' read -r MAJOR MINOR PATCH <<< "$(VERSION)" && echo "$${MAJOR}.$${MINOR}.$$((PATCH + 1))")

SWIFT_SRCS = \
	Sources/main.swift \
	Sources/Version.swift \
	Sources/Daemon.swift \
	Sources/VM.swift \
	Sources/IPC.swift \
	Sources/State.swift \
	Sources/Setup.swift

OBJC_SRCS = Sources/MSLVSOCK.m
OBJC_HEADER = Sources/BridgingHeader.h

all: sign

# Generate Version.swift before compiling. This is a phony target so it
# always runs and regenerates the file with the correct version.
gen-version:
	@echo 'import Foundation' > $(VERSION_FILE)
	@echo 'let MSLVersion = "$(VERSION)"' >> $(VERSION_FILE)

$(PRODUCT): gen-version $(filter-out Sources/Version.swift,$(SWIFT_SRCS)) $(OBJC_SRCS)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) \
		-import-objc-header $(OBJC_HEADER) \
		-o $@ \
		$(SWIFT_SRCS) $(OBJC_SRCS)
	@echo "Build complete: $(PRODUCT) (v$(VERSION))"

sign: $(PRODUCT)
	codesign --entitlements Resources/msl.entitlements \
		--force \
		--sign - \
		$(PRODUCT)
	@echo "Signed: $(PRODUCT)"

clean:
	rm -rf $(BUILD_DIR)

# ─────────────────────────────────────────────────────────────────────
# Release: build, commit, tag, push msl repo, then update & push homebrew tap.
#
# Usage:
#   make release MSG="production hardening"
#
# What it does:
#   1. Auto-computes next version from latest git tag (patch +1)
#   2. Builds the binary with that version to verify it compiles
#   3. Stages all changes, commits, pushes to origin
#   4. Tags v<version> and pushes the tag
#   5. Downloads the new GitHub tarball and computes sha256
#   6. Clones/pulls homebrew-msl tap at /tmp/homebrew-msl
#   7. Updates url + sha256 in Formula/msl.rb and Formula/msld.rb
#   8. Commits and pushes the tap
#
# No manual version bumping needed — version is derived from git tags.
#
# Notes:
# - Code signing uses ad-hoc identity (--sign -) because msl doesn't have
#   a paid Apple Developer ID. Users may see a Gatekeeper warning on first
#   run. To fix permanently: obtain a Developer ID, replace --sign - with
#   --sign "Developer ID Application: ...", and notarize the binary.
# ─────────────────────────────────────────────────────────────────────
release: build-check
	@echo "Releasing v$(VERSION_NEXT) ..."; \
	git add -A; \
	git commit -m "$(MSG)"; \
	git pull --rebase; \
	git push; \
	git tag "v$(VERSION_NEXT)"; \
	git push origin "v$(VERSION_NEXT)"; \
	echo "Tagged v$(VERSION_NEXT), downloading tarball..."; \
	SHA=$$(curl -sL "https://github.com/xt9y/msl/archive/refs/tags/v$(VERSION_NEXT).tar.gz" | shasum -a 256 | awk '{print $$1}'); \
	echo "sha256: $$SHA"; \
	if [ -d /tmp/homebrew-msl ]; then \
		cd /tmp/homebrew-msl && git pull; \
	else \
		git clone https://github.com/xt9y/homebrew-msl.git /tmp/homebrew-msl; \
	fi; \
	sed -i '' "s|url \".*\"|url \"https://github.com/xt9y/msl/archive/refs/tags/v$(VERSION_NEXT).tar.gz\"|" /tmp/homebrew-msl/Formula/msl.rb /tmp/homebrew-msl/Formula/msld.rb; \
	sed -i '' "s|sha256 \".*\"|sha256 \"$$SHA\"|" /tmp/homebrew-msl/Formula/msl.rb /tmp/homebrew-msl/Formula/msld.rb; \
	cd /tmp/homebrew-msl && git add Formula/msl.rb Formula/msld.rb && \
	git commit -m "$(MSG)" && git push; \
	echo "Done: v$(VERSION_NEXT) published to homebrew."

# Build-check: compile with the next version and verify the binary runs.
build-check:
	@echo 'import Foundation' > $(VERSION_FILE)
	@echo 'let MSLVersion = "$(VERSION_NEXT)"' >> $(VERSION_FILE)
	@mkdir -p $(BUILD_DIR)
	@$(SWIFTC) $(SWIFT_FLAGS) \
		-import-objc-header $(OBJC_HEADER) \
		-o $(PRODUCT) \
		$(SWIFT_SRCS) $(OBJC_SRCS) || { echo "ERROR: build failed"; exit 1; }
	@codesign --entitlements Resources/msl.entitlements --force --sign - $(PRODUCT) 2>/dev/null
	@./$(PRODUCT) version | head -1 | grep -q "msl" && echo "Binary OK (v$(VERSION_NEXT))" || { echo "ERROR: binary test failed"; exit 1; }

.PHONY: all sign clean release build-check gen-version