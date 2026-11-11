#!/bin/bash
# build.sh [install]: build the Mac window's title bar plugin (libdecor's cairo plugin, made
# to look like GTK's Yaru-dark header bar); with "install", put it where mac26.sh loads it.
#
# The source is libdecor 0.2.2 (the tarball here) with vmlab-titlebar.patch applied, kept
# unpacked in libdecor-0.2.2/. After a change of the desktop's icon theme: gen-icons.py first.
# The build tree is $BUILD (default /vmlab/tmp/libdecor-vmlab-build); its demo/libdecor-demo
# shows the title bar without a VM:
#   LIBDECOR_PLUGIN_DIR=$BUILD/src/plugins/cairo $BUILD/demo/libdecor-demo
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
build=${BUILD:-/vmlab/tmp/libdecor-vmlab-build}

[ -d "$build" ] || meson setup "$build" "$here/libdecor-0.2.2" -Dgtk=disabled -Ddbus=disabled -Dbuildtype=release
meson compile -C "$build"
echo "built: $build/src/plugins/cairo/libdecor-cairo.so"

if [ "${1:-}" = install ]; then
    install -m 644 "$build/src/plugins/cairo/libdecor-cairo.so" "$here/../libdecor-cairo/libdecor-cairo.so"
    echo "installed: $(readlink -f "$here/../libdecor-cairo/libdecor-cairo.so")"
fi
