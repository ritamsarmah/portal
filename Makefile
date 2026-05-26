include .env
export

.PHONY: all debug run compile deploy clean

OUT := build
PROJECT := portal
HOST := pi@portal
REMOTE := $(HOST):/home/pi

all: debug

debug:
	odin run . -debug -o:none

run:
	odin run .

# Compile only produces object files to link on Raspberry Pi
compile: clean
	mkdir -p $(OUT)
	odin build . -target=linux_arm64 -build-mode=object -out:$(OUT)

# Deploy to remote device and finish linking with system libraries
deploy: compile
	rsync -avz --delete $(OUT)/ $(REMOTE)/$(OUT)/
	ssh $(HOST) "ld build/*.o -o portal -lSDL3 -lSDL3_image -lpthread -ldl -lm -lc -lcurl -dynamic-linker /lib/ld-linux-aarch64.so.1 -e main::main"

clean:
	rm -rf $(OUT) $(PROJECT)
