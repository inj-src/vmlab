#!/usr/bin/env bash
# build-guest-kmd.sh: build the guest's kernel display driver (viogpu3d.sys) again with the local
# patches in kmd-patches/ on top of the release's own two, and test-sign it with the lab's own
# key (signing/, made on the first run; the release's key is its authors'). Output: guest-kmd/.
# About 10 minutes the first time (300 MB of Microsoft's driver kit), 2 after. Run it as a
# systemd-run --user unit.
#
#   build-guest-kmd.sh            build and sign
#   build-guest-kmd.sh install    put the built viogpu3d.sys into the running VM (then restart it)
#
# Same inputs as release 0.1.2-alpha: vmlab-win3d at the commit in guest/README.txt, built by its
# own build/kmd/build.sh and signed by its build/signing/, with podman in place of docker (as
# build-guest-umd.sh, which made the checkout in /vmlab/tmp/win3d-src).
set -euo pipefail
HERE=/vmlab/tools/vmlab/gpu/win3d
REPO=$HERE/../win-research/vmlab-win3d
WORK=/vmlab/tmp/win3d-src
OUT=$HERE/guest-kmd
export WIN3D_CACHE=/vmlab/tmp/win3d-cache
COMMIT=$(tr -d '\r' < "$HERE/guest/README.txt" | grep -A1 'at commit$' | grep -o -E '[0-9a-f]{40}' || true)
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || { echo "no release commit in guest/README.txt" >&2; exit 1; }

if [[ ${1:-} == install ]]; then
  W=$HERE/win-venus.sh
  [[ -f $OUT/viogpu3d.sys ]] || { echo "build first" >&2; exit 1; }
  "$W" scp "$OUT/viogpu3d.sys" "$OUT/vmlab-test-signing.cer" dev@127.0.0.1:
  # Windows runs the driver from its package's folder in the driver store, which belongs to
  # SYSTEM: take the folder, move the running file aside (it cannot be overwritten), copy.
  # HWCursor=1 turns the driver's pointer support on (kmd-patches/0003); the certificate goes
  # in so Windows shows the file as signed (in its test-signing mode the kernel loads it anyway).
  "$W" ssh '
    $ErrorActionPreference = "Stop"
    certutil -f -addstore Root "$HOME\vmlab-test-signing.cer" | Out-Null
    certutil -f -addstore TrustedPublisher "$HOME\vmlab-test-signing.cer" | Out-Null
    $sys = (Get-CimInstance Win32_SystemDriver | Where-Object Name -eq VioGpu3D).PathName
    $dir = Split-Path $sys
    takeown /f $dir /r /d y | Out-Null; icacls $dir /grant "Administrators:(OI)(CI)F" /t /q | Out-Null
    if (-not (Test-Path "$sys.release")) { Copy-Item $sys "$sys.release" }       # the release driver, kept once
    Move-Item $sys "$sys.old-$(Get-Date -Format yyyyMMddHHmmss)"; Copy-Item "$HOME\viogpu3d.sys" $sys
    Remove-Item "$HOME\viogpu3d.sys", "$HOME\vmlab-test-signing.cer"
    $key = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}" -ErrorAction SilentlyContinue |
      Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).InfSection -like "VioGpu3D*" -or (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DriverDesc -like "*VirtIO GPU 3D*" }
    foreach ($k in $key) { Set-ItemProperty $k.PSPath HWCursor 1 -Type DWord; "HWCursor=1 in $($k.PSChildName)" }
    "{0} {1}" -f (Get-AuthenticodeSignature $sys).Status, (Get-FileHash $sys -Algorithm SHA256).Hash.ToLower()'
  sha256sum "$OUT/viogpu3d.sys"
  exit
fi

if [[ $(git -C "$WORK" rev-parse HEAD 2>/dev/null) != "$COMMIT" ]]; then
  git -C "$REPO" worktree prune
  rm -rf "$WORK"
  git -C "$REPO" worktree add --no-checkout --detach "$WORK" "$COMMIT" > /dev/null
  git -C "$WORK" sparse-checkout set --cone build patches > /dev/null
  git -C "$WORK" checkout -q "$COMMIT"
fi
git -C "$WORK" clean -qfd patches/kmd                     # local patches from an earlier run
git -C "$WORK" checkout -q -- patches/kmd
for p in "$HERE"/kmd-patches/*.patch; do [[ -f $p ]] && { echo "local patch ${p##*/}"; cp "$p" "$WORK/patches/kmd/"; }; done

# The compiler is the one build-guest-umd.sh fetched, if it did: the same pinned file
mkdir -p "$WIN3D_CACHE/dl"
tc=$WORK/build/toolchain/llvm-mingw.tar.xz
[[ -f $tc ]] && cp -n "$tc" "$WIN3D_CACHE/dl/$(awk '$1 == "llvm-mingw" { print $3 }' "$WORK/build/kmd/PINS" | sed 's#.*/##')"

# The signing image pins Debian package versions that Debian has since replaced: take today's
git -C "$WORK" checkout -q -- build/signing/Dockerfile
sed -i -E 's/\b(osslsigncode|openssl|gcc|make|libc6-dev)=[^ ]+/\1/g' "$WORK/build/signing/Dockerfile"

# The signing key lives with the tools, not in the temporary checkout
mkdir -p "$HERE/signing"; chmod 700 "$HERE/signing"
ln -sfn "$HERE/signing" "$WORK/.signing"

# their scripts call `docker`; give them podman, rootless, storing on the VM SSD (build-guest-umd.sh)
bin=$(mktemp -d); trap 'rm -rf "$bin"' EXIT
[[ -d /vmlab/tmp/podman ]] || { mkdir -p /vmlab/tmp/podman; chgrp "$(id -gn)" /vmlab/tmp/podman; chmod g-s /vmlab/tmp/podman; }
cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  [[ $a == --user ]] && { skip=1; args+=(--userns=keep-id); continue; }
  [[ -n ${skip:-} ]] && { skip=; continue; }
  args+=("$a")
done
exec podman --root /vmlab/tmp/podman/root --storage-driver overlay \
  --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs "${args[@]}"
EOF
chmod +x "$bin/docker"
export PATH=$bin:$PATH

"$WORK/build/kmd/build.sh"
"$WORK/build/signing/make-test-cert.sh" > /dev/null
"$WORK/build/signing/sign-driver.sh" "$WORK/out/kmd/x64"

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$WORK/out/kmd/x64/viogpu3d.sys" "$WORK/out/kmd/BUILDINFO" "$OUT/"
cp "$HERE/signing/test-signing.cer" "$OUT/vmlab-test-signing.cer"
{ echo; echo "vmlab-win3d $COMMIT (release 0.1.2-alpha) plus:"; ls "$HERE/kmd-patches"; } >> "$OUT/BUILDINFO"
sha256sum "$OUT/viogpu3d.sys"
