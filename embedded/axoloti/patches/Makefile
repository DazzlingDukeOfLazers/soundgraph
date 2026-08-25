# Builds Axoloti test patches against the stock 1.0.12-2 firmware SDK.
# Run ../tools/fetch-sdk.sh once to populate ../sdk (axoloti.elf, ramlink.ld).
#
# The flags mirror the patcher's Makefile.patch, minus the ChibiOS include
# jungle (our patches declare the ABI themselves in axo_abi.h), plus
# -fno-reorder-functions: ramlink.ld only places *(.boot) and *(.text), so
# nothing may end up in .text.unlikely/.text.hot subsections.

SDK ?= ../sdk

# CRC32 of the stock 1.0.12-2 firmware flash image; xpatch_init refuses to run
# under any other firmware build (the link symbols would be wrong).
FWID = 0xe95bac96

CXX = arm-none-eabi-g++
OBJCOPY = arm-none-eabi-objcopy
NM = arm-none-eabi-nm

CXXFLAGS = -nostdlib -ffreestanding -fno-exceptions -fno-rtti -mcpu=cortex-m4 -O3 \
  -fomit-frame-pointer -falign-functions=16 -mfloat-abi=hard \
  -mfpu=fpv4-sp-d16 -mthumb -std=c++17 -fno-math-errno \
  -fno-threadsafe-statics -fno-use-cxa-atexit -fno-reorder-functions \
  -Wall -Wextra -Wdouble-promotion -I../../../dsp-core/src -DSG_EXPECTED_FWID=$(FWID)

LDFLAGS = -nostdlib -nostartfiles -T$(SDK)/ramlink.ld -mcpu=cortex-m4 \
  -mfloat-abi=hard -mfpu=fpv4-sp-d16 -mthumb \
  -Wl,--just-symbols=$(SDK)/axoloti.elf

PATCHES = smoke looplab nodelab stresslab
BINS = $(PATCHES:%=build/%.bin)

all: $(BINS)

build:
	mkdir -p build

build/%.o: %.cpp axo_abi.h sg_shm.h sg_lab.h | build
	$(CXX) $(CXXFLAGS) -c $< -o $@

build/%.elf: build/%.o $(SDK)/ramlink.ld $(SDK)/axoloti.elf
	$(CXX) $(LDFLAGS) $< -Wl,-Map=build/$*.map -o $@
	@# The firmware jumps to the first byte of the binary: xpatch_init must
	@# sit exactly at the SRAM origin, and nothing may land in .data (the
	@# linker script marks it NOLOAD, so its contents would never arrive).
	@$(NM) $@ | grep -q "^00011000 T xpatch_init$$" || \
	  { echo "ERROR: xpatch_init is not at 0x11000 in $@"; exit 1; }
	@if $(OBJCOPY) -O binary -j .data $@ build/$*.data.tmp 2>/dev/null && \
	  [ -s build/$*.data.tmp ]; then \
	  echo "ERROR: $* has initialized .data (NOLOAD) — make it const or init at runtime"; \
	  rm -f build/$*.data.tmp; exit 1; fi; rm -f build/$*.data.tmp

build/%.bin: build/%.elf
	$(OBJCOPY) -O binary $< $@
	@echo "$*: $$(wc -c < $@ | tr -d ' ') bytes"

clean:
	rm -rf build

.PHONY: all clean
.SECONDARY:  # keep .elf/.map for debugging
