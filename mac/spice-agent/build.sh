#!/bin/bash
# build.sh: compile the agent with the Command Line Tools' swiftc (no Xcode needed). Run in the VM.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -swift-version 5 -module-name vmlab_spice_agent -o build/vmlab-spice-agent Sources/*.swift
echo "built $(pwd)/build/vmlab-spice-agent"
