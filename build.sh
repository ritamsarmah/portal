#!/usr/bin/env sh

ld build/*.o -o portal \
    -lSDL3 -lpthread -ldl -lm -lc \
    -dynamic-linker /lib/ld-linux-aarch64.so.1 \
    -e main::main
