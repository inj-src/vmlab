#!/usr/bin/env python3
"""make-firmware.py [IN [OUT]]: the Windows VM's firmware, made from the system's OVMF
(/usr/share/OVMF/OVMF_CODE_4M.fd -> OVMF_CODE_4M.vmlab.fd beside this file), with a quiet start:

  1. no TianoCore logo. The driver that hands the firmware its logo (LogoDxe) is never started
     (its dependency expression is made FALSE), so the firmware draws none and gives Windows
     none to keep (no BGRT table): Windows then draws its own logo while it starts.
  2. no "BdsDxe: loading Boot0003 ..." and "BdsDxe: starting Boot0003 ..." lines on the screen
     (the format string they share is emptied). Messages about a failed start stay.

Nothing is rebuilt from source: the image's one compressed file is unpacked, those bytes are
changed, and it is packed again (fv.py). OUT.sha256 records the IN this OUT was made from;
win-venus.sh makes OUT again when the system's file changes (a package update).
"""
import hashlib, lzma, os, struct, sys, uuid
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fv as F

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1] if len(sys.argv) > 1 else '/usr/share/OVMF/OVMF_CODE_4M.fd'
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, 'OVMF_CODE_4M.vmlab.fd')
LOGO_DXE = uuid.UUID('f74d20ee-37e7-48fc-97f7-9b1047749c69')
QUIET = ['%a: %a %s "%s" from %s\n']        # "BdsDxe: loading Boot0003 ...", and "starting"
DEPEX_FALSE_END = b'\x07\x08'


def die(msg):
    sys.exit(f'make-firmware: {msg}')


def unpack(image):
    """The compressed file of the image's first volume: (volume offset and length, the file's
    place in it, the unpacked bytes, the compressed stream's 5 property bytes)."""
    vols = F.volumes(image)
    if not vols:
        die('no firmware volume')
    off, length = vols[0]
    vol = image[off:off + length]
    fs, _ = F.files(vol)
    if len(fs) != 1 or fs[0][4] != F.FILE_FV_IMAGE:
        die('the first volume is not one compressed file')
    at, hlen, size, g, ftype, attrs = fs[0]
    body = vol[at + hlen:at + size]
    secs = F.sections(body)
    if len(secs) != 1 or secs[0][3] != F.SEC_GUID_DEFINED:
        die('the file is not one GUID-defined section')
    so, sh, ss, _ = secs[0]
    if F.guid(body[so + sh:so + sh + 16]) != F.LZMA:
        die('the section is not LZMA')
    data_off, sec_attrs = struct.unpack_from('<HH', body, so + sh + 16)
    stream = body[so + data_off:so + ss]
    inner = lzma.decompress(stream, format=lzma.FORMAT_ALONE)
    return (off, length), (at, g, ftype, attrs, vol[at + 23]), (data_off, sec_attrs), inner, stream[:5]


def pack(inner, props):
    """inner as an LZMA stream the firmware's own unpacker reads: the first stream's properties
    and dictionary, and the unpacked size in the header (liblzma writes "unknown" there and
    ends the stream with a marker; the size is put in, the marker stays, which the unpacker
    takes)."""
    lc_lp_pb, dict_size = props[0], struct.unpack_from('<I', props, 1)[0]
    lc, rest = lc_lp_pb % 9, lc_lp_pb // 9
    filt = [{'id': lzma.FILTER_LZMA1, 'dict_size': dict_size, 'lc': lc, 'lp': rest % 5, 'pb': rest // 5,
             'preset': 9 | lzma.PRESET_EXTREME}]
    stream = bytearray(lzma.compress(inner, format=lzma.FORMAT_ALONE, filters=filt))
    if bytes(stream[:5]) != bytes(props):
        die('the packed stream has other properties than the original')
    stream[5:13] = struct.pack('<Q', len(inner))
    return bytes(stream)


def quiet(inner):
    """The changes (the module doc), on the unpacked bytes. What was changed, in words."""
    inner = bytearray(inner)
    done = []
    for so, sh, ss, stype in F.sections(inner):
        if stype != F.SEC_FV_IMAGE:
            continue
        base = so + sh
        vol = inner[base:base + ss - sh]
        for at, hlen, size, g, ftype, attrs in F.files(vol)[0]:
            if g != LOGO_DXE:
                continue
            body = base + at + hlen
            first = F.sections(vol[at + hlen:at + size])[0]
            if first[3] != 0x13 or first[2] - first[1] < 2:
                die('LogoDxe does not start with a dependency expression')
            if attrs & 0x40:
                die('LogoDxe has a checksum over its body')
            p = body + first[0] + first[1]
            inner[p:p + 2] = DEPEX_FALSE_END
            done.append('LogoDxe is never started (no logo, no BGRT)')
    if not done:
        die('no LogoDxe in the firmware')
    for text in QUIET:
        raw = text.encode('utf-16le')
        n = inner.count(raw)
        if n != 1:
            die(f'{n} copies of the message {text!r}, wanted 1')
        p = inner.find(raw)
        inner[p:p + 2] = b'\0\0'
        done.append('no "loading Boot..." and "starting Boot..." lines')
    return bytes(inner), done


image = open(SRC, 'rb').read()
(off, length), (at, g, ftype, attrs, state), (data_off, sec_attrs), inner, props = unpack(image)
new_inner, done = quiet(inner)
stream = pack(new_inner, props)
# the section, the file, and the volume around them: free space after the file is 0xFF
sec_size = data_off + len(stream)
if sec_size >= 0xFFFFFF:
    die('the packed section is too large')
section = sec_size.to_bytes(3, 'little') + bytes([F.SEC_GUID_DEFINED]) + F.LZMA.bytes_le + struct.pack('<HH', data_off, sec_attrs)
section += b'\0' * (data_off - len(section)) + stream
ffs = F.file_header(g, ftype, attrs, section, state) + section
if at + len(ffs) > length:
    die('the packed file does not fit its volume')
vol = bytearray(image[off:off + length])
vol[at:] = ffs + b'\xff' * (length - at - len(ffs))
out = image[:off] + bytes(vol) + image[off + length:]
# read it back as the firmware would
_, _, _, check, _ = unpack(out)
if check != new_inner or len(out) != len(image):
    die('the new image does not read back')
tmp = OUT + '.tmp'
open(tmp, 'wb').write(out)
os.replace(tmp, OUT)
open(OUT + '.sha256', 'w').write(hashlib.sha256(image).hexdigest() + '\n')
changed = sum(a != b for a, b in zip(inner, new_inner))
print(f'{OUT}: from {SRC}; {changed} bytes changed inside; ' + '; '.join(done))
