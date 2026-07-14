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

GUEST_SRC = Guest/msld.c
GUEST_OUT = $(BUILD_DIR)/msld

all: sign

$(GUEST_OUT): $(GUEST_SRC)
	@mkdir -p $(BUILD_DIR)
	aarch64-linux-musl-gcc -static -Os -s -o $@ $^

$(PRODUCT): $(SWIFT_SRCS) $(OBJC_SRCS) $(GUEST_OUT)
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

run: sign
	$(BUILD_DIR)/msl $(ARGS)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all sign run clean
