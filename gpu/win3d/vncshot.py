# vncshot.py PORT FILE.png: one frame from a VNC server on 127.0.0.1 that asks no password
import socket, struct, sys
from PIL import Image
s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), 10); s.settimeout(15)
def rd(n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise EOFError
        b += c
    return b
rd(12); s.sendall(b'RFB 003.008\n')
n = rd(1)[0]; types = rd(n); s.sendall(b'\x01'); assert rd(4) == b'\0\0\0\0', types
s.sendall(b'\x01'); w, h = struct.unpack('>HH', rd(4)); rd(16); rd(struct.unpack('>I', rd(4))[0])
s.sendall(struct.pack('>BxxxBBBBHHHBBBxxx', 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))   # BGRX little-endian
s.sendall(struct.pack('>BxHi', 2, 1, 0)); s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, w, h))
img = Image.new('RGB', (w, h)); got = 0
while got < w * h:
    t = rd(1)[0]
    if t != 0: raise SystemExit(f'unexpected message {t}')
    rd(1); (nr,) = struct.unpack('>H', rd(2))
    for _ in range(nr):
        x, y, rw, rh, enc = struct.unpack('>HHHHi', rd(12))
        if enc != 0: raise SystemExit(f'encoding {enc}')
        img.paste(Image.frombuffer('RGB', (rw, rh), rd(rw * rh * 4), 'raw', 'BGRX', 0, 1), (x, y)); got += rw * rh
img.save(sys.argv[2]); print(w, h)
