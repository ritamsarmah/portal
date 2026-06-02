#!/usr/bin/env bash

set -a
source .env
set +a

nc -lk 0.0.0.0 9041 | ./portal
