SWIFTC = xcrun swiftc
SWIFT_FLAGS = -framework Virtualization -O -Xcc -fobjc-arc
BUILD_DIR = build
PRODUCT = $(BUILD_DIR)/msl
GUEST = $(BUILD_DIR)/msld
VERSION_FILE = Sources/Version.swift
GUEST_SRC = Guest/msld.c
ZIG ?= zig

SWIFT_SRCS = \
	Sources/Version.swift \
	Sources/main.swift \
	Sources/Daemon.swift \
	Sources/VM.swift \
	Sources/IPC.swift \
	Sources/State.swift \
	Sources/Setup.swift

OBJC_SRCS = Sources/MSLVSOCK.m
OBJC_HEADER = Sources/BridgingHeader.h

all: $(VERSION_FILE) $(PRODUCT) $(GUEST) sign

# Version.swift is a proper prerequisite of $(PRODUCT) via SWIFT_SRCS.
# When .git is available, we always regenerate so the version string
# reflects the exact commit, dirty-state, and distance-from-tag.
# When .git is absent (e.g. a release tarball), the file shipped in
# the archive survives unchanged — the Homebrew formula also writes
# the correct version before invoking make sign.
$(VERSION_FILE):
	@echo 'import Foundation' > $(VERSION_FILE)
	@if test -d .git; then \
	  GIT_VERSION=$$(git describe --tags --dirty --always 2>/dev/null | sed 's/^v//'); \
	else \
	  GIT_VERSION="0.0.0-dev"; \
	fi; \
	echo "let MSLVersion = \"$$GIT_VERSION\"" >> $(VERSION_FILE)
	@echo "  -> Version: $$(grep MSLVersion $(VERSION_FILE) | sed 's/.*"\(.*\)"/\1/')"

$(PRODUCT): $(SWIFT_SRCS) $(OBJC_SRCS)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) \
		-import-objc-header $(OBJC_HEADER) \
		-o $@ \
		$(SWIFT_SRCS) $(OBJC_SRCS)
	@echo "Build complete: $(PRODUCT) (v$$(grep MSLVersion $(VERSION_FILE) | sed 's/.*"\(.*\)"/\1/'))"

$(GUEST): $(GUEST_SRC)
	@mkdir -p $(BUILD_DIR)
	$(ZIG) cc -target aarch64-linux-musl -static -Os -s -o $@ $(GUEST_SRC)

clean:
	rm -rf $(BUILD_DIR)

DEV_ID ?= -

sign: $(PRODUCT)
	codesign --entitlements Resources/msl.entitlements \
		--force --sign "$(DEV_ID)" "$(PRODUCT)"

test: $(PRODUCT)
	./build/msl version
	./build/msl help | grep -q start
	./build/msl help | grep -q shell
	./build/msl help | grep -q exec
	@echo "All smoke tests passed"

check-c: $(GUEST_SRC)
	$(ZIG) cc -target aarch64-linux-musl -static -Os -s \
		-Wall -Wextra -Werror -o /dev/null $(GUEST_SRC)
	@echo "C strict check passed"

.PHONY: all clean sign test check-c $(VERSION_FILE)
