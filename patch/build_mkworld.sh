#!/bin/sh
# Build the custom mkworld tool against a ZeroTierOne source tree.
# ZeroTierOne 1.16 removed attic/world (and its build.sh) and renamed
# node/C25519.* to node/ECC.*, so mkworld is built from here instead.
#
# Usage: build_mkworld.sh <ZeroTierOne source dir> <mkworld_custom.cpp> <output binary>
set -eu

ZT_SRC=${1:?ZeroTierOne source dir required}
MKWORLD_SRC=${2:?mkworld source required}
OUT=${3:-mkworld}

c++ -std=c++17 -O2 \
    -I"${ZT_SRC}" -I"${ZT_SRC}/ext" -I"${ZT_SRC}/node" \
    -o "${OUT}" \
    "${ZT_SRC}/node/ECC.cpp" \
    "${ZT_SRC}/node/Salsa20.cpp" \
    "${ZT_SRC}/node/SHA512.cpp" \
    "${ZT_SRC}/node/Identity.cpp" \
    "${ZT_SRC}/node/Utils.cpp" \
    "${ZT_SRC}/node/InetAddress.cpp" \
    "${ZT_SRC}/osdep/OSUtils.cpp" \
    "${MKWORLD_SRC}" \
    -lm

echo "mkworld built: ${OUT}"
