"""Fake Cua Driver MCP server for the integration tests: `fake_cua.py <log-dir> <machine>`.

Speaks newline-delimited JSON-RPC on stdio. Tools:
  echo      returns {"machine": <argv machine>, "args": <arguments>, "pid": <pid>} as text
  sleep     sleeps `seconds`, sending progress if the request has a progressToken
  image     returns one image block and one text block with annotations
  fail      returns a JSON-RPC error (-32602)
  die       exits the process without answering (simulates a VM reboot)
  huge      answers with a text block padded so the response line is exactly `bytes` long
            (without its newline)
Writes its pid to <log-dir>/<machine>.pid and events (calls, cancelled ids) to
<log-dir>/<machine>.log. FAKE_CUA_LIST=<seconds> delays the tools/list answer; "hang" never sends it.
"""
import json, os, sys, threading, time

log_dir, machine = sys.argv[1], sys.argv[2]
lock = threading.Lock()
cancelled = set()

with open(os.path.join(log_dir, f"{machine}.pid"), "a") as f:
    f.write(f"{os.getpid()}\n")

def log(line):
    with open(os.path.join(log_dir, f"{machine}.log"), "a") as f:
        f.write(line + "\n")

def send(obj):
    with lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

TOOLS = [
    {"name": n, "description": f"fake {n}", "inputSchema": {"type": "object", "properties": {"seconds": {"type": "number"}}}}
    for n in ["echo", "sleep", "image", "fail", "die", "huge"]
]

IMAGE = [
    {"type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"},
    {"type": "text", "text": "w=1 h=1", "annotations": {"audience": ["assistant"], "priority": 0.5}},
]

def call(rid, params):
    name, args = params["name"], params.get("arguments") or {}
    meta = params.get("_meta") or {}
    log(f"call {name}")
    if name == "echo":
        send({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": json.dumps({"machine": machine, "args": args, "pid": os.getpid(), "meta": meta})}]}})
    elif name == "sleep":
        end = time.time() + float(args.get("seconds", 1))
        token, step = meta.get("progressToken"), 0
        while time.time() < end:
            if rid in cancelled:
                log(f"cancelled {rid}")
                return
            if token is not None:
                step += 1
                send({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": token, "progress": step, "message": f"step {step}"}})
            time.sleep(0.1)
        send({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "slept"}]}})
    elif name == "image":
        send({"jsonrpc": "2.0", "id": rid, "result": {"content": IMAGE, "structuredContent": {"w": 1, "h": 1}}})
    elif name == "fail":
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "bad window id", "data": {"hint": "x"}}})
    elif name == "die":
        os._exit(3)
    elif name == "huge":
        line = lambda n: json.dumps({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "x" * n}]}})
        body = line(int(args["bytes"]) - len(line(0)))
        log(f"huge {len(body)}")
        with lock:
            sys.stdout.write(body + "\n")
            sys.stdout.flush()

for line in sys.stdin:
    msg = json.loads(line)
    method, rid = msg.get("method"), msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "fake-cua", "version": "0"}}})
    elif method == "tools/list":
        delay = os.environ.get("FAKE_CUA_LIST", "")
        if delay == "hang":
            continue
        if delay:
            time.sleep(float(delay))
        send({"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        threading.Thread(target=call, args=(rid, msg["params"]), daemon=True).start()
    elif method == "notifications/cancelled":
        cancelled.add(msg["params"].get("requestId"))
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
    elif rid is not None:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no such method"}})
log("stdin closed")
