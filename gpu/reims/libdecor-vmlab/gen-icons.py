"""gen-icons.py OUT.h: the title bar's button icons as alpha masks, for libdecor-cairo.c (vmlab).

The desktop's icon theme's symbolic icons, the ones GTK shows in a header bar, drawn at 16
units for the scales 1, 2 and 3. Run by build.sh; run it again after a change of icon theme.
"""
import sys
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Rsvg', '2.0')
import cairo
from gi.repository import Gtk, Rsvg

ICONS = {'close': 'window-close-symbolic', 'maximize': 'window-maximize-symbolic',
         'restore': 'window-restore-symbolic', 'minimize': 'window-minimize-symbolic',
         'fullscreen': 'view-fullscreen-symbolic'}
theme = Gtk.IconTheme.get_default()
out = ['/* made by gen-icons.py: alpha masks of the symbolic icons, 16 units at scales 1 to 3 */',
       '#define VMLAB_ICON_UNITS 16', '#define VMLAB_ICON_SCALES 3']
for name, icon in ICONS.items():
    info = theme.lookup_icon(icon, 16, Gtk.IconLookupFlags.FORCE_SVG)
    path = info.get_filename()
    handle = Rsvg.Handle.new_from_file(path)
    for scale in (1, 2, 3):
        size = 16 * scale
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
        cr = cairo.Context(surface)
        rect = Rsvg.Rectangle()
        rect.x = rect.y = 0
        rect.width = rect.height = size
        handle.render_document(cr, rect)
        surface.flush()
        data, stride = surface.get_data(), surface.get_stride()
        alpha = [data[y * stride + x * 4 + 3] for y in range(size) for x in range(size)]
        out.append(f'/* {icon}, {path} */' if scale == 1 else '')
        out.append(f'static const unsigned char vmlab_icon_{name}_{scale}[{size * size}] = {{')
        for i in range(0, len(alpha), 24):
            out.append('\t' + ','.join(str(a) for a in alpha[i:i + 24]) + ',')
        out.append('};')
    out.append(f'static const unsigned char *const vmlab_icon_{name}[3] = '
               f'{{ vmlab_icon_{name}_1, vmlab_icon_{name}_2, vmlab_icon_{name}_3 }};')
open(sys.argv[1], 'w').write('\n'.join(out) + '\n')
