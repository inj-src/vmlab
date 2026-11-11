"""fv.py: read and rebuild the parts of a UEFI firmware image (PI firmware volumes) that
make-logo.py needs. Volumes of FFS2/FFS3 files; sections; one LZMA-compressed section."""
import lzma, struct, uuid

FFS2 = uuid.UUID('8c8ce578-8a3d-4f1c-9935-896185c32dd3')
FFS3 = uuid.UUID('5473c07a-3dcb-4dca-bd6f-1e9689e7349a')
LZMA = uuid.UUID('ee4e5898-3914-4259-9d6e-dc7bd79403cf')
PAD = uuid.UUID('ffffffff-ffff-ffff-ffff-ffffffffffff')
SEC_COMPRESSION, SEC_GUID_DEFINED, SEC_FV_IMAGE, SEC_RAW = 0x01, 0x02, 0x17, 0x19
FILE_FREEFORM, FILE_FV_IMAGE, FILE_PAD = 0x02, 0x0B, 0xF0


def guid(b):
    return uuid.UUID(bytes_le=bytes(b))


def volumes(data):
    """Offsets of the firmware volumes in data ('_FVH' at +40, a known file system)."""
    out, at = [], 0
    while True:
        at = data.find(b'_FVH', at)
        if at < 0:
            return out
        start = at - 40
        if start >= 0 and guid(data[start + 16:start + 32]) in (FFS2, FFS3):
            length = struct.unpack_from('<Q', data, start + 32)[0]
            if start + length <= len(data):
                out.append((start, length))
        at += 4


def fv_header_len(fv):
    return struct.unpack_from('<H', fv, 48)[0]


def files(fv):
    """(offset, header length, total length, guid, type, attributes) of each file in the volume."""
    at = fv_header_len(fv)
    ext = struct.unpack_from('<H', fv, 52)[0]
    if ext:                                  # the extended header is skipped over
        at = ext + struct.unpack_from('<I', fv, ext + 16)[0]
    at = (at + 7) & ~7
    out = []
    while at + 24 <= len(fv) and fv[at:at + 24] != b'\xff' * 24:
        g, ftype, attrs = guid(fv[at:at + 16]), fv[at + 18], fv[at + 19]
        size = int.from_bytes(fv[at + 20:at + 23], 'little')
        hlen = 24
        if attrs & 0x01:                     # FFS_ATTRIB_LARGE_FILE: 64-bit size after the header
            size = struct.unpack_from('<Q', fv, at + 24)[0]
            hlen = 32
        if size < hlen or at + size > len(fv):
            raise ValueError(f'bad file size at {at:#x}')
        out.append((at, hlen, size, g, ftype, attrs))
        at = (at + size + 7) & ~7
    return out, at                           # at: where free space starts


def sections(body):
    """(offset, header length, total length, type) of each section in a file's body."""
    at, out = 0, []
    while at + 4 <= len(body):
        size = int.from_bytes(body[at:at + 3], 'little')
        stype, hlen = body[at + 3], 4
        if size == 0xFFFFFF:
            size = struct.unpack_from('<I', body, at + 4)[0]
            hlen = 8
        if size < hlen or at + size > len(body):
            raise ValueError(f'bad section size at {at:#x}')
        out.append((at, hlen, size, stype))
        at = (at + size + 3) & ~3
    return out


def section(stype, payload):
    size = len(payload) + 4
    if size < 0xFFFFFF:
        return size.to_bytes(3, 'little') + bytes([stype]) + payload
    return b'\xff\xff\xff' + bytes([stype]) + struct.pack('<I', size + 4) + payload


def sum8(b):
    return (-sum(b)) & 0xFF


def file_header(g, ftype, attrs, body, state):
    """A file's header for body: its sizes and checksums (PI 1.x, EFI_FFS_FILE_HEADER[2])."""
    large = len(body) + 24 > 0xFFFFFF
    attrs = (attrs | 0x01) if large else (attrs & ~0x01)
    hlen = 32 if large else 24
    size = len(body) + hlen
    h = bytearray(g.bytes_le + b'\0\0' + bytes([ftype, attrs]) +
                  (b'\0\0\0' if large else size.to_bytes(3, 'little')) + b'\0')
    if large:
        h += struct.pack('<Q', size)
    h[16] = sum8(h)                                               # header: all but state and the file checksum
    h[17] = sum8(body) if attrs & 0x40 else 0xAA                  # FFS_ATTRIB_CHECKSUM
    h[23] = state
    return bytes(h)
