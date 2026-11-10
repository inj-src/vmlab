#!/usr/bin/env python3
"""hold_client.py SECONDS: connect the headless SPICE client (main channel only) and sit idle,
so CPU can be measured with a client attached (the agent polls the pasteboard only then).
Exits 3 if the connection drops (the user opened the viewer)."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_agent as T  # noqa: E402

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 60
c = T.Client()
print(f"connected; agent caps ok; holding {secs:.0f} s", flush=True)
end = time.monotonic() + secs
try:
    while time.monotonic() < end:
        c.pump(1)
except T.TookOver:
    print("connection dropped: the user took over", flush=True)
    sys.exit(3)
c.close()
