#!/usr/bin/env bash
# build-guest-umd.sh: build the guest's Mesa drivers again (viogpu_d3d10.dll, the Direct3D 9-11
# driver, and its two siblings) with the local patches in guest-patches/ on top of the release's
# own series. Output: guest-umd/{x64,x86}/. About 25 minutes the first time (it builds the
# driver authors' toolchain image), 15 after. Run it as a systemd-run --user unit.
#
#   build-guest-umd.sh            build
#   build-guest-umd.sh install    copy the built viogpu_d3d10.dll into the running VM (then restart it)
#
# Same inputs as release 0.1.2-alpha: vmlab-win3d at the commit in guest/README.txt, built by its
# own build/mesa/build.sh, with podman in place of docker (no root; images and layers are kept
# on the VM SSD, in /vmlab/tmp/podman/root).
set -euo pipefail
HERE=/vmlab/tools/vmlab/gpu/win3d
REPO=$HERE/../win-research/vmlab-win3d           # a blob-less clone: files are fetched on checkout
WORK=/vmlab/tmp/win3d-src
OUT=$HERE/guest-umd
COMMIT=$(tr -d '\r' < "$HERE/guest/README.txt" | grep -A1 'at commit$' | grep -o -E '[0-9a-f]{40}' || true)
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || { echo "no release commit in guest/README.txt" >&2; exit 1; }

if [[ ${1:-} == install ]]; then
  W=$HERE/win-venus.sh
  [[ -f $OUT/x64/viogpu_d3d10.dll ]] || { echo "build first" >&2; exit 1; }
  "$W" scp "$OUT/x64/viogpu_d3d10.dll" dev@127.0.0.1:viogpu_d3d10.x64.dll
  "$W" scp "$OUT/x86/viogpu_d3d10.dll" dev@127.0.0.1:viogpu_d3d10.x86.dll
  # A loaded DLL can be renamed but not overwritten: move the old one aside, then copy. Programs
  # started from now on load the new one; dwm and the rest do after a restart of Windows.
  "$W" ssh '
    foreach ($p in @(@("x64", "$env:WINDIR\System32"), @("x86", "$env:WINDIR\SysWOW64"))) {
      $new = "$HOME\viogpu_d3d10.$($p[0]).dll"; $dst = "$($p[1])\viogpu_d3d10.dll"
      if (-not (Test-Path "$dst.release")) { Copy-Item $dst "$dst.release" }      # the release DLL, kept once
      $old = "$dst.old-$(Get-Date -Format yyyyMMddHHmmss)"
      Move-Item $dst $old; Copy-Item $new $dst; Remove-Item $new
      Remove-Item "$($p[1])\viogpu_d3d10.dll.old-*" -ErrorAction SilentlyContinue  # fails while loaded: fine
      "{0} {1}" -f $p[0], (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
    }'
  sha256sum "$OUT"/x64/viogpu_d3d10.dll "$OUT"/x86/viogpu_d3d10.dll
  exit
fi

if [[ $(git -C "$WORK" rev-parse HEAD 2>/dev/null) != "$COMMIT" ]]; then
  git -C "$REPO" worktree prune
  rm -rf "$WORK"
  git -C "$REPO" worktree add --no-checkout --detach "$WORK" "$COMMIT" > /dev/null
  git -C "$WORK" sparse-checkout set --cone build patches > /dev/null
  git -C "$WORK" checkout -q "$COMMIT"
fi
git -C "$WORK" clean -qfd patches/mesa                    # local patches from an earlier run
git -C "$WORK" checkout -q -- patches/mesa
for p in "$HERE"/guest-patches/*.patch; do [[ -f $p ]] && { echo "local patch ${p##*/}"; cp "$p" "$WORK/patches/mesa/"; }; done

# The toolchain image takes its build tools (cmake, ninja, python) from Ubuntu's snapshot service,
# which is sometimes down. Then take today's from the archive: the compiler (llvm-mingw) and
# Meson are pinned downloads either way.
git -C "$WORK" checkout -q -- build/toolchain/Dockerfile
snap=$(sed -n 's/^ARG UBUNTU_SNAPSHOT=//p' "$WORK/build/toolchain/Dockerfile")
if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://snapshot.ubuntu.com/ubuntu/$snap/dists/noble/InRelease") != 200 ]]; then
  echo "snapshot.ubuntu.com is not answering: build tools come from archive.ubuntu.com"
  sed -i 's#https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/#http://archive.ubuntu.com/ubuntu/#g' "$WORK/build/toolchain/Dockerfile"
fi

# podman 4 builds have no `ADD --checksum`: fetch and check the compiler here, and COPY it in
tc=$WORK/build/toolchain
git -C "$WORK" checkout -q -- build/toolchain/.dockerignore
name=$(sed -n 's/^ARG LLVM_MINGW=//p' "$tc/Dockerfile")
sum=$(grep -o 'ADD --checksum=sha256:[0-9a-f]*' "$tc/Dockerfile" | cut -d: -f2)
url=$(sed -n 's#^ *\(https://github.com/mstorsjo/llvm-mingw[^ ]*\) .*#\1#p' "$tc/Dockerfile" | sed "s/\${LLVM_MINGW}/$name/")
[[ -n $name && -n $sum && -n $url ]] || { echo "toolchain Dockerfile changed: no llvm-mingw ADD line" >&2; exit 1; }
echo "$sum  $tc/llvm-mingw.tar.xz" | sha256sum -c --status 2>/dev/null || curl -fsSL --retry 3 -o "$tc/llvm-mingw.tar.xz" "$url"
echo "$sum  $tc/llvm-mingw.tar.xz" | sha256sum -c --quiet
python3 -I - "$tc/Dockerfile" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s, n = re.subn(r'ADD --checksum=\S+ \\\n\s+\S+ \\\n\s+/tmp/llvm-mingw\.tar\.xz', 'COPY llvm-mingw.tar.xz /tmp/llvm-mingw.tar.xz', s)
assert n == 1
open(sys.argv[1], 'w').write(s)
PY
echo '!llvm-mingw.tar.xz' >> "$tc/.dockerignore"

# their scripts call `docker`; give them podman, rootless, storing on the VM SSD
bin=$(mktemp -d); trap 'rm -rf "$bin"' EXIT
# its directory: the user's own group and no setgid bit, which /vmlab's directories pass on and
# which podman's user namespace cannot chown
[[ -d /vmlab/tmp/podman ]] || { mkdir -p /vmlab/tmp/podman; chgrp "$(id -gn)" /vmlab/tmp/podman; chmod g-s /vmlab/tmp/podman; }
cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  # as the invoking user inside the container, so the output files are theirs
  [[ $a == --user ]] && { skip=1; args+=(--userns=keep-id); continue; }
  [[ -n ${skip:-} ]] && { skip=; continue; }
  args+=("$a")
done
# fuse-overlayfs: the kernel's overlay refuses a rootless mount on this disk
exec podman --root /vmlab/tmp/podman/root --storage-driver overlay \
  --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs "${args[@]}"
EOF
chmod +x "$bin/docker"
PATH=$bin:$PATH "$WORK/build/mesa/build.sh"

rm -rf "$OUT"; mkdir -p "$OUT"
cp -r "$WORK/out/mesa/x64" "$WORK/out/mesa/x86" "$OUT/"
{ echo "vmlab-win3d $COMMIT (release 0.1.2-alpha) plus:"; ls "$HERE/guest-patches"; } > "$OUT/BUILDINFO"
sha256sum "$OUT"/x64/*.dll "$OUT"/x86/*.dll
