#!/usr/bin/env bash
# build-qemu.sh: build vmlab-win3d's patched QEMU again, here, with what their release build
# leaves out: the GTK and SDL windows, user-mode networking, io_uring and PipeWire sound.
# Output: opt/qemu-ui/ (opt/qemu/, their release binary, stays as it is). About 10 minutes.
#
#   build-qemu.sh            fetch (first time), configure and build
#   build-qemu.sh rebuild    build again after editing the source in $WORK/qemu
#
# Same source as the release: the commit in src/qemu-vmlab-egl-*/BUILDINFO on VMLabDev/qemu,
# and virglrenderer 1.3.0 with the two patches named there. Only the virglrenderer headers
# come from this build; at run time QEMU loads the release's libvirglrenderer.so.1 (a copy in
# opt/qemu-ui/lib, found through an absolute rpath, so opt/qemu-ui cannot be moved).
# Local changes to QEMU are the patches in qemu-patches/, applied in order.
set -euo pipefail
HERE=/vmlab/tools/vmlab/gpu/win3d
WORK=/vmlab/tmp/win-qemu
OUT=$HERE/opt/qemu-ui
DOCS=$HERE/../win-research/vmlab-win3d      # their repository, for the virglrenderer patches
COMMIT=$(awk '$1 == "commit:" { print $2 }' "$HERE"/src/qemu-vmlab-egl-*/BUILDINFO)
VIRGL_URL=https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/1.3.0/virglrenderer-1.3.0.tar.gz
VIRGL_SHA=065bc56e89e6f631f96101cd62eba0748e48eb888b434edc86e89d05395e76f3
mkdir -p "$WORK"; cd "$WORK"

if [[ ${1:-} != rebuild ]]; then
  if [[ ! -f virgl-dev/usr/lib/pkgconfig/virglrenderer.pc ]]; then
    [[ -f virgl.tar.gz ]] || curl -fsSL -o virgl.tar.gz "$VIRGL_URL"
    echo "$VIRGL_SHA  virgl.tar.gz" | sha256sum -c --quiet
    rm -rf virglrenderer-1.3.0; tar -xf virgl.tar.gz; cd virglrenderer-1.3.0
    for p in 0001-vkr-log-image-creation.patch 0002-vkr-do-not-create-queue-sync-fences-exportable.patch; do
      git -C "$DOCS" show "HEAD:patches/host/virglrenderer/$p" | patch -s -p1
    done
    meson setup b --prefix=/usr --libdir=lib --libexecdir=libexec --buildtype=release \
      -Dplatforms=egl -Dvenus=true -Drender-server-worker=process -Dvideo=false -Dtests=false > ../virgl-setup.log
    ninja -C b > ../virgl-build.log
    DESTDIR=$WORK/virgl-dev meson install -C b --quiet
    sed -i "s|^prefix=/usr|prefix=$WORK/virgl-dev/usr|" "$WORK/virgl-dev/usr/lib/pkgconfig/virglrenderer.pc"
    cd "$WORK"
  fi
  if [[ $(git -C qemu rev-parse HEAD 2>/dev/null) != "$COMMIT" ]]; then
    rm -rf qemu; mkdir -p qemu; cd qemu; git init -q
    git fetch -q --depth 32 https://github.com/VMLabDev/qemu "$COMMIT"
    git -c advice.detachedHead=false checkout -q FETCH_HEAD
    for p in "$HERE"/qemu-patches/*.patch; do [[ -f $p ]] && { echo "applying ${p##*/}"; git apply "$p"; }; done
    cd "$WORK"
  fi
  cd qemu
  PKG_CONFIG_PATH=$WORK/virgl-dev/usr/lib/pkgconfig \
  ./configure --prefix=/usr --target-list=x86_64-softmmu --with-pkgversion="vmlab ${COMMIT:0:12} +ui" \
    --without-default-features --enable-system --disable-user --disable-tools --disable-guest-agent --disable-docs \
    --enable-kvm --enable-tcg --enable-pixman --enable-opengl --enable-virglrenderer --enable-vnc \
    --enable-tpm --enable-libusb --enable-vhost-user --enable-zstd --enable-hmp --enable-malloc-trim \
    --enable-gtk --enable-spice-protocol --enable-sdl --enable-slirp --enable-linux-io-uring --enable-linux-aio \
    --enable-pipewire --audio-drv-list=pipewire --enable-png \
    --disable-werror --extra-cflags="-march=native" --extra-ldflags="-Wl,-rpath,$OUT/lib" > "$WORK/configure.log"
  cd "$WORK"
fi

cd "$WORK/qemu"
make -j"$(nproc)" qemu-system-x86_64 > "$WORK/make.log" 2>&1 || { tail -40 "$WORK/make.log" >&2; exit 1; }
mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/share"
cp build/qemu-system-x86_64 "$OUT/bin/"
cp "$HERE/opt/qemu/lib/libvirglrenderer.so.1" "$OUT/lib/"
ln -sfn /usr/share/qemu "$OUT/share/qemu"
"$OUT/bin/qemu-system-x86_64" --version | head -1
"$OUT/bin/qemu-system-x86_64" -display help | tr '\n' ' '; echo
