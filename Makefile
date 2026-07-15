SWIFTC = xcrun swiftc
SWIFT_FLAGS = -framework Virtualization -O -Xcc -fobjc-arc
BUILD_DIR = build
PRODUCT = $(BUILD_DIR)/msl
VERSION_FILE = Sources/Version.swift

VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0-dev")

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

all: $(PRODUCT)

gen-version:
	@echo 'import Foundation' > $(VERSION_FILE)
	@echo 'let MSLVersion = "$(VERSION)"' >> $(VERSION_FILE)

$(PRODUCT): gen-version $(SWIFT_SRCS) $(OBJC_SRCS)
	@mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(SWIFT_FLAGS) \
		-import-objc-header $(OBJC_HEADER) \
		-o $@ \
		$(SWIFT_SRCS) $(OBJC_SRCS)
	@echo "Build complete: $(PRODUCT) (v$(VERSION))"

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all clean gen-version
