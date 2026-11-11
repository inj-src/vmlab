"""cmp.py GUEST.png SCREEN.png [GUEST_WIDTH]: where the guest's picture is in the screen capture, and how exact."""
import sys, numpy as np
from PIL import Image
g = np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(np.int16)
n = np.asarray(Image.open(sys.argv[2]).convert('RGB')).astype(np.int16)
if len(sys.argv) > 3: g = g[:, :int(sys.argv[3])]
gh, gw = g.shape[:2]; nh, nw = n.shape[:2]
# a patch with detail: the busiest 48x48 block of the guest picture
best = None
for y in range(0, gh - 48, 48):
    for x in range(0, gw - 48, 48):
        v = g[y:y+48, x:x+48].std()
        if best is None or v > best[0]: best = (v, x, y)
_, px, py = best
patch = g[py:py+48, px:px+48]
res = None
for oy in range(0, nh - gh + 1):
    for ox in range(0, nw - gw + 1):
        d = np.abs(n[oy+py:oy+py+48, ox+px:ox+px+48] - patch).mean()
        if res is None or d < res[0]: res = (d, ox, oy)
d, ox, oy = res
print(f'guest {gw}x{gh}, screen {nw}x{nh}; picture at screen pixel ({ox},{oy}), patch error {d:.3f}')
diff = np.abs(n[oy:oy+gh, ox:ox+gw] - g).max(axis=2)
print(f'whole picture: {100*(diff==0).mean():.2f}% of pixels identical, {100*(diff<=2).mean():.2f}% within 2 levels, mean error {diff.mean():.3f}, max {diff.max()}')
