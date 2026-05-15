#!/usr/bin/env bash

code=${1:?Missing code argument}
host=${2:-127.0.0.1}

# Send 32-bit value as big-endian bytes
perl -e 'print pack("N", shift)' "$code" | nc "$host" 9041
