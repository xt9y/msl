SWIFTC = xcrun swiftc
SWIFT_FLAGS = -framework Virtualization -O -Xcc -fobjc-arc
BUILD_DIR = build
PRODUCT = $(BUILD_DIR)/msl
GUEST = $(BUILD_DIR)/msld
VERSION_FILE = Sources/Version.swift
GUEST_SRC = Guest/msld.c

SWIFT_SRCS = \
	Sources/main.swift \
	Sources/Daemon.swift \
	Sources/VM.swift \
	Sources/IPC.swift \
	Sources/State.swift \
	Sources/Setup.swift

OBJC_SRCS = Sources/MSLVSOCK.m
OBJC_HEADER = Sources/BridgingHeader.h

all: $(PRODUCT) $(GUEST) sign-prod

$(VERSION_FILE):
	@echo 'import Foundation' > $(VERSION_FILE)
	@GIT_VERSION=$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0-dev"); \
	 echo "let MSLVersion = \"$$GIT_VERSION\"" >> $(VERSION_FILE)

$(PRODUCT): $(VERSION_FILE) $(SWIFT_SRCS) $(OBJC_SRCS)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) \
		-import-objc-header $(OBJC_HEADER) \
		-o $@ \
		$(VERSION_FILE) $(SWIFT_SRCS) $(OBJC_SRCS)
	@echo "Build complete: $(PRODUCT) (v$$(grep MSLVersion $(VERSION_FILE) | sed 's/.*"\(.*\)"/\1/'))"

$(GUEST): $(GUEST_SRC)
	@mkdir -p $(BUILD_DIR)
	zig cc -target aarch64-linux-musl -static -Os -s -o $@ $(GUEST_SRC)

clean:
	rm -rf $(BUILD_DIR)

DEV_ID ?= -

sign: $(PRODUCT)
	codesign --entitlements Resources/msl.entitlements \
		--force --sign "$(DEV_ID)" "$(PRODUCT)"

sign-prod: $(PRODUCT)
	codesign --entitlements Resources/msl.entitlements \
		--force --sign "-" "$(PRODUCT)"

.PHONY: all clean sign sign-prod
