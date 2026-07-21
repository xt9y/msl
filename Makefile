SWIFTC = xcrun swiftc
SWIFT_FLAGS = -framework Virtualization -O -Xcc -fobjc-arc
BUILD_DIR = build
PRODUCT = $(BUILD_DIR)/msl
GUEST = $(BUILD_DIR)/msld
VERSION_FILE = Sources/Version.swift
GUEST_SRC = Guest/msld.c
ZIG ?= zig

SWIFT_SRCS = \
	Sources/main.swift \
	Sources/Daemon.swift \
	Sources/VM.swift \
	Sources/IPC.swift \
	Sources/State.swift \
	Sources/Setup.swift

OBJC_SRCS = Sources/MSLVSOCK.m
OBJC_HEADER = Sources/BridgingHeader.h

all: $(VERSION_FILE) $(PRODUCT) $(GUEST) sign

$(VERSION_FILE):
	@echo 'import Foundation' > $(VERSION_FILE)
	@GIT_VERSION=$$(git describe --tags --abbrev=0 2>/dev/null) && \
	 GIT_VERSION=$$(echo "$$GIT_VERSION" | sed 's/^v//') || \
	 GIT_VERSION="0.0.0-dev"; \
	 echo "let MSLVersion = \"$$GIT_VERSION\"" >> $(VERSION_FILE)
	@echo "  -> Version: $$(grep MSLVersion $(VERSION_FILE) | sed 's/.*"\(.*\)"/\1/')"

$(PRODUCT): $(SWIFT_SRCS) $(OBJC_SRCS)
	@test -s $(VERSION_FILE) 2>/dev/null || $(MAKE) $(VERSION_FILE)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) \
		-import-objc-header $(OBJC_HEADER) \
		-o $@ \
		$(VERSION_FILE) $(SWIFT_SRCS) $(OBJC_SRCS)
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
