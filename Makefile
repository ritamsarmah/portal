.PHONY: all debug run compile deploy clean

OUT := build
PROJECT := portal
HOST := pi@portal
REMOTE := $(HOST):/home/pi

all: debug

debug:
	mkdir -p $(OUT)
	odin build . -debug -o:none -out:$(OUT)/$(APP)

run:
	odin run .

# Compile only produces object files to link on Raspberry Pi
compile: clean
	mkdir -p $(OUT)
	odin build . -target=linux_arm64 -build-mode=object -out:$(OUT)

deploy: compile
	rsync -avz --delete $(OUT)/ $(REMOTE)/$(OUT)/
	rsync -avz build.sh $(REMOTE)
	ssh $(HOST) "./build.sh"

clean:
	rm -rf $(OUT)
