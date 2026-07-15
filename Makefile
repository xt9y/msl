SWIFTC = xcrun swiftc
SWIFT_FLAGS = -framework Virtualization -O -Xcc -fobjc-arc
BUILD_DIR = build
PRODUCT = $(BUILD_DIR)/msl

SWIFT_SRCS = \
	Sources/main.swift \
	Sources/Daemon.swift \
	Sources/VM.swift \
	Sources/IPC.swift \
	Sources/State.swift \
	Sources/Setup.swift

OBJC_SRCS = Sources/MSLVSOCK.m
OBJC_HEADER = Sources/BridgingHeader.h

all: sign

$(PRODUCT): $(SWIFT_SRCS) $(OBJC_SRCS)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) \
		-import-objc-header $(OBJC_HEADER) \
		-o $@ \
		$(SWIFT_SRCS) $(OBJC_SRCS)
	@echo "Build complete: $(PRODUCT)"

sign: $(PRODUCT)
	codesign --entitlements Resources/msl.entitlements \
		--force \
		--sign - \
		$(PRODUCT)
	@echo "Signed: $(PRODUCT)"

clean:
	rm -rf $(BUILD_DIR)

# ─────────────────────────────────────────────────────────────────────
# Release: commit, tag, push msl repo, then update & push homebrew tap.
#
# Usage:
#   make release MSG="v1.0.8: fix {...}"
#
# What it does:
#   1. Reads the version from Sources/Setup.swift (MSLVersion)
#   2. Commits all staged changes with MSG
#   3. Pushes to origin and tags v<version>
#   4. Downloads the new GitHub tarball and computes sha256
#   5. Clones/pulls homebrew-msl tap at /tmp/homebrew-msl
#   6. Updates url + sha256 in Formula/msl.rb and Formula/msld.rb
#   7. Commits and pushes the tap
#
# Prerequisites:
#   - Bump MSLVersion in Sources/Setup.swift BEFORE running
# ─────────────────────────────────────────────────────────────────────
release:
	git add -A
	@VER=$$(grep -o 'MSLVersion = "[^"]*"' Sources/Setup.swift | grep -o '[0-9]*\.[0-9]*\.[0-9]*'); \
	echo "Releasing v$$VER ..."; \
	git commit -m "$(MSG)"; \
	git push; \
	git tag "v$$VER"; \
	git push origin "v$$VER"; \
	echo "Tagged v$$VER, downloading tarball..."; \
	SHA=$$(curl -sL "https://github.com/xt9y/msl/archive/refs/tags/v$$VER.tar.gz" | shasum -a 256 | awk '{print $$1}'); \
	echo "sha256: $$SHA"; \
	if [ -d /tmp/homebrew-msl ]; then \
		cd /tmp/homebrew-msl && git pull; \
	else \
		git clone https://github.com/xt9y/homebrew-msl.git /tmp/homebrew-msl; \
	fi; \
	sed -i '' "s|url \".*\"|url \"https://github.com/xt9y/msl/archive/refs/tags/v$$VER.tar.gz\"|" /tmp/homebrew-msl/Formula/msl.rb /tmp/homebrew-msl/Formula/msld.rb; \
	sed -i '' "s|sha256 \".*\"|sha256 \"$$SHA\"|" /tmp/homebrew-msl/Formula/msl.rb /tmp/homebrew-msl/Formula/msld.rb; \
	cd /tmp/homebrew-msl && git add Formula/msl.rb Formula/msld.rb && \
	git commit -m "$(MSG)" && git push; \
	echo "Done: v$$VER published to homebrew."

.PHONY: all sign clean release
