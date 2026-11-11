#!/usr/bin/env bash
# build.sh: build the layer here. `build.sh test` also prints the NVIDIA card's memory types
# without and with it (needs libvulkan-dev).
set -euo pipefail
cd "$(dirname "$0")"
gcc -O2 -Wall -Wextra -fPIC -fvisibility=hidden -shared -o libVkLayer_vmlab_coherent_memory.so coherent_memory.c
echo "built $PWD/libVkLayer_vmlab_coherent_memory.so"
[[ ${1:-} == test ]] || exit 0
gcc -O2 -Wall -o memtypes memtypes.c -lvulkan
export VK_LOADER_DRIVERS_SELECT='*nvidia*'
echo "== without the layer"; ./memtypes
echo "== with the layer"; VK_LAYER_PATH=$PWD VK_INSTANCE_LAYERS=VK_LAYER_VMLAB_coherent_memory ./memtypes
