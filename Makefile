include .env
export

.PHONY: all debug run compile miniaudio raylib dependencies deploy clean

OUT := build
PROJECT := portal
HOST := pi@portal
HOME_DIR := /home/pi
REMOTE := $(HOST):$(HOME_DIR)

RAYLIB_VERSION := 6.0

all: debug

debug:
	odin run . -debug -o:none

run:
	odin run .

# Compile object files to link on Raspberry Pi
compile: clean
	mkdir -p $(OUT)
	odin build . -target=linux_arm64 -build-mode=object -out:$(OUT)

# Download and compile miniaudio on Raspberry Pi
miniaudio:
	ssh $(HOST) "\
		mkdir -p $(HOME_DIR)/miniaudio/lib && \
		cd $(HOME_DIR)/miniaudio && \
		wget -q https://raw.githubusercontent.com/mackron/miniaudio/master/miniaudio.c && \
		wget -q https://raw.githubusercontent.com/mackron/miniaudio/master/miniaudio.h && \
		$(CC) -c -O2 -fPIC miniaudio.c -o miniaudio.o && \
		$(AR) rcs lib/libminiaudio.a miniaudio.o && \
		rm miniaudio.*"

# Download and compile raylib on Raspberry Pi with DRM backend
# https://github.com/raysan5/raylib/wiki/Working-on-Raspberry-Pi#compiling-raylib-source-code
raylib:
	ssh $(HOST) "\
		sudo apt install -y libdrm-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev && \
		wget -q -O raylib.tar.gz https://github.com/raysan5/raylib/archive/refs/tags/$(RAYLIB_VERSION).tar.gz && \
		tar -xvf raylib.tar.gz && \
		rm raylib.tar.gz && \
		mv raylib-$(RAYLIB_VERSION) raylib/ && \
		cd raylib/src && \
		sed -i 's/SUPPORT_FILEFORMAT_JPG.*0/SUPPORT_FILEFORMAT_JPG      1/' config.h && \
		make PLATFORM=PLATFORM_DRM"

curl:
	ssh $(HOST) "sudo apt install -y libcurl4-openssl-dev"

# Install library dependencies
dependencies: miniaudio raylib curl
	@echo "Installed dependencies"

# Deploy to remote device and finish linking
deploy: compile
	rsync -avz --delete $(OUT)/ $(REMOTE)/$(OUT)/
	rsync -avz server.sh $(REMOTE)/server.sh
	ssh $(HOST) "\
		gcc build/*.o -o portal \
		-L$(HOME_DIR)/raylib/src \
		-L$(HOME_DIR)/miniaudio/lib \
		-Wl,-Bstatic -lraylib -lminiaudio \
		-Wl,-Bdynamic -lGLESv2 -lEGL -lgbm -ldrm -latomic -lpthread -lm -lc -lcurl \
		-dynamic-linker /lib/ld-linux-aarch64.so.1"

clean:
	rm -rf $(OUT) $(PROJECT)
