"""boot-shots.py DIR [SECONDS [STEP]]: pictures of the Windows VM's screen while it starts, one
every STEP seconds (0.5) for SECONDS (25), as DIR/NN.N.png, through QEMU's monitor socket
(screendump). Run it right after `win-venus.sh start`. For looking at the firmware's screen."""
import json, socket, sys, time
out, secs, step = sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 25.0, float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
s = socket.socket(socket.AF_UNIX)
s.connect('/vmlab/run/win-venus/qmp.sock')
f = s.makefile('rw')


def cmd(name, **args):
    f.write(json.dumps({'execute': name, 'arguments': args}) + '\n')
    f.flush()
    while True:
        r = json.loads(f.readline())
        if 'return' in r or 'error' in r:
            return r


f.readline()
cmd('qmp_capabilities')
t0 = time.time()
while time.time() - t0 < secs:
    t = time.time() - t0
    r = cmd('screendump', filename=f'{out}/{t:05.1f}.png', format='png')
    if 'error' in r:
        print(t, r['error'].get('desc'))
    time.sleep(max(0, step - (time.time() - t0 - t)))
