#!/bin/sh
set -e
cd "$(dirname "$0")"

# Init solidity submodules (range-v3, fmt, etc.) if needed
git -C ../../vendor/solidity submodule update --init --recursive

# Build via cmake — add_subdirectory handles solidity + all deps
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . --target yul_ref -- -j"$(nproc)"
echo "Built: $(pwd)/yul_ref"
