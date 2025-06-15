# Makefile from ChatGPT

FCODE_UTILS = ../fcode-utils/toke
FCODE_SRC = rtl8139.fth
FCODE_OUT = rtl8139.fc
ROM_OUT = combined.rom
MACOS_DRIVER = macos_driver_patched
DRIVER_OFFSET = 4096

.PHONY: all clean

all: $(ROM_OUT)

$(FCODE_OUT): $(FCODE_SRC)
	$(FCODE_UTILS)/toke $(FCODE_SRC)

$(ROM_OUT): $(FCODE_OUT) $(MACOS_DRIVER)
	cp $(FCODE_OUT) $(ROM_OUT)
	dd if=$(MACOS_DRIVER) of=$(ROM_OUT) bs=1 seek=$(DRIVER_OFFSET)

clean:
	rm -f $(FCODE_OUT) $(ROM_OUT)
