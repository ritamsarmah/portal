#!/usr/bin/env bash

code=${1:?Missing code argument}
host=${2:-127.0.0.1}

printf "$code" | nc "$host" 9041
