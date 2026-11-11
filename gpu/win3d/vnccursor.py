# vnccursor.py PORT FILE.png: the guest's pointer image as QEMU has it (VNC's alpha-cursor
# message), on a grey checkerboard and enlarged 6 times. Prints its size and hot spot.
import socket, struct, sys
from PIL import Image
s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), 10); s.settimeout(10)
def rd(n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise EOFError
        b += c
    return b
rd(12); s.sendall(b'RFB 003.008\n')
n = rd(1)[0]; rd(n); s.sendall(b'\x01'); assert rd(4) == b'\0\0\0\0'
s.sendall(b'\x01'); w, h = struct.unpack('>HH', rd(4)); rd(16); rd(struct.unpack('>I', rd(4))[0])
s.sendall(struct.pack('>BxxxBBBBHHHBBBxxx', 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
s.sendall(struct.pack('>BxHii', 2, 2, 0, -314)); s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, 16, 16))
while True:
    t = rd(1)[0]
    if t != 0: raise SystemExit(f'unexpected message {t}')
    rd(1); (nr,) = struct.unpack('>H', rd(2))
    for _ in range(nr):
        x, y, rw, rh, enc = struct.unpack('>HHHHi', rd(12))
        if enc == 0: rd(rw * rh * 4); continue
        if enc != -314: raise SystemExit(f'encoding {enc}')
        assert struct.unpack('>i', rd(4))[0] == 0
        cur = Image.frombuffer('RGBA', (rw, rh), rd(rw * rh * 4), 'raw', 'BGRA', 0, 1)   # QEMU sends its own byte order
        bg = Image.new('RGBA', (rw, rh))
        bg.putdata([(150, 150, 150, 255) if (i % rw // 8 + i // rw // 8) % 2 else (90, 90, 90, 255) for i in range(rw * rh)])
        Image.alpha_composite(bg, cur).resize((rw * 6, rh * 6), Image.NEAREST).save(sys.argv[2])
        print(f'{rw}x{rh} hot spot {x},{y}'); raise SystemExit
